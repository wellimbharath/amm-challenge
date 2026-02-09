"""
Convex-style optimization of adaptive fee strategy parameters.

Uses scipy.optimize.differential_evolution (global optimizer that handles
noisy, non-convex objectives) to search over the strategy parameter space.
Calls the Rust simulation engine directly for speed.
"""

import sys
import os
import time
import numpy as np
from scipy.optimize import differential_evolution

# Force single worker to avoid segfaults
os.environ["N_WORKERS"] = "1"

from amm_competition.evm.compiler import SolidityCompiler
from amm_competition.evm.adapter import EVMStrategyAdapter
from amm_competition.evm.baseline import load_vanilla_strategy
from amm_competition.competition.match import MatchRunner, HyperparameterVariance
from amm_competition.competition.config import (
    BASELINE_SETTINGS,
    BASELINE_VARIANCE,
    baseline_nominal_sigma,
    baseline_nominal_retail_rate,
    baseline_nominal_retail_size,
)
import amm_sim_rs

# ──────────────── Solidity template ────────────────
# Parameters injected: MAX_FEE_BPS, RETAIL_FEE_BPS, ARB_MULT_X10, DECAY_PCT
STRATEGY_TEMPLATE = """
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {{AMMStrategyBase}} from "./AMMStrategyBase.sol";
import {{IAMMStrategy, TradeInfo}} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {{
    uint256 constant SLOT_BID = 0;
    uint256 constant SLOT_ASK = 1;
    uint256 constant SLOT_EMA_SIZE = 2;
    uint256 constant SLOT_LAST_DIR = 3;
    uint256 constant SLOT_CONSEC = 4;

    uint256 constant MAX_FEE_CAP = {max_fee_bps} * BPS;
    uint256 constant RETAIL_FEE = {retail_fee_bps} * BPS;
    uint256 constant ALPHA = WAD / 5;
    uint256 constant ONE_MINUS_ALPHA = WAD - ALPHA;
    uint256 constant ARB_MULT = {arb_mult_x10} * WAD / 10;
    uint256 constant DECAY_NUM = {decay_pct};

    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {{
        slots[SLOT_BID] = MAX_FEE_CAP;
        slots[SLOT_ASK] = MAX_FEE_CAP;
        slots[SLOT_EMA_SIZE] = WAD / 100;
        return (MAX_FEE_CAP, MAX_FEE_CAP);
    }}

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {{
        uint256 sizeRatio = wdiv(trade.amountY, trade.reserveY);

        uint256 ema = slots[SLOT_EMA_SIZE];
        ema = ema == 0 ? sizeRatio : wmul(ALPHA, sizeRatio) + wmul(ONE_MINUS_ALPHA, ema);
        slots[SLOT_EMA_SIZE] = ema;

        uint256 dir = trade.isBuy ? 1 : 2;
        uint256 lastDir = slots[SLOT_LAST_DIR];
        uint256 consec = (dir == lastDir) ? slots[SLOT_CONSEC] + 1 : 1;
        slots[SLOT_LAST_DIR] = dir;
        slots[SLOT_CONSEC] = consec;

        bool likelyArb = sizeRatio > wmul(ARB_MULT, ema) || consec >= 3;

        uint256 bidFee;
        uint256 askFee;

        if (likelyArb) {{
            if (trade.isBuy) {{
                bidFee = RETAIL_FEE;
                askFee = MAX_FEE_CAP;
            }} else {{
                askFee = RETAIL_FEE;
                bidFee = MAX_FEE_CAP;
            }}
        }} else {{
            uint256 prevBid = slots[SLOT_BID];
            uint256 prevAsk = slots[SLOT_ASK];
            bidFee = prevBid < MAX_FEE_CAP
                ? prevBid + wmul(DECAY_NUM * WAD / 100, MAX_FEE_CAP - prevBid)
                : MAX_FEE_CAP;
            askFee = prevAsk < MAX_FEE_CAP
                ? prevAsk + wmul(DECAY_NUM * WAD / 100, MAX_FEE_CAP - prevAsk)
                : MAX_FEE_CAP;
        }}

        if (bidFee > MAX_FEE_CAP) bidFee = MAX_FEE_CAP;
        if (askFee > MAX_FEE_CAP) askFee = MAX_FEE_CAP;
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[SLOT_BID] = bidFee;
        slots[SLOT_ASK] = askFee;

        return (bidFee, askFee);
    }}

    function getName() external pure override returns (string memory) {{
        return "OptStrategy";
    }}
}}
"""

N_SIMS = 30  # max reliable sim count
compiler = SolidityCompiler()
vanilla = load_vanilla_strategy()

eval_count = 0
best_edge = -1e9
best_params = None


def evaluate(params):
    """Objective function: compile strategy from params, run sims, return -edge."""
    global eval_count, best_edge, best_params
    eval_count += 1

    max_fee_bps = int(round(params[0]))
    retail_fee_bps = int(round(params[1]))
    arb_mult_x10 = int(round(params[2]))
    decay_pct = int(round(params[3]))

    # Enforce constraints
    if retail_fee_bps > max_fee_bps:
        retail_fee_bps = max_fee_bps
    if retail_fee_bps < 1:
        retail_fee_bps = 1
    if arb_mult_x10 < 10:
        arb_mult_x10 = 10
    if decay_pct < 5:
        decay_pct = 5
    if decay_pct > 95:
        decay_pct = 95

    source = STRATEGY_TEMPLATE.format(
        max_fee_bps=max_fee_bps,
        retail_fee_bps=retail_fee_bps,
        arb_mult_x10=arb_mult_x10,
        decay_pct=decay_pct,
    )

    try:
        result = compiler.compile(source)
        if not result.success:
            print(f"  [{eval_count}] COMPILE FAIL: max={max_fee_bps} retail={retail_fee_bps} arb_mult={arb_mult_x10/10:.1f} decay={decay_pct}%")
            return 0.0  # penalty: 0 edge

        strategy = EVMStrategyAdapter(bytecode=result.bytecode, abi=result.abi)

        config = amm_sim_rs.SimulationConfig(
            n_steps=BASELINE_SETTINGS.n_steps,
            initial_price=BASELINE_SETTINGS.initial_price,
            initial_x=BASELINE_SETTINGS.initial_x,
            initial_y=BASELINE_SETTINGS.initial_y,
            gbm_mu=BASELINE_SETTINGS.gbm_mu,
            gbm_sigma=baseline_nominal_sigma(),
            gbm_dt=BASELINE_SETTINGS.gbm_dt,
            retail_arrival_rate=baseline_nominal_retail_rate(),
            retail_mean_size=baseline_nominal_retail_size(),
            retail_size_sigma=BASELINE_SETTINGS.retail_size_sigma,
            retail_buy_prob=BASELINE_SETTINGS.retail_buy_prob,
            seed=None,
        )

        runner = MatchRunner(
            n_simulations=N_SIMS,
            config=config,
            n_workers=1,
            variance=BASELINE_VARIANCE,
        )
        match_result = runner.run_match(strategy, vanilla)
        avg_edge = float(match_result.total_edge_a) / N_SIMS

        if avg_edge > best_edge:
            best_edge = avg_edge
            best_params = (max_fee_bps, retail_fee_bps, arb_mult_x10 / 10, decay_pct)

        print(
            f"  [{eval_count:3d}] max={max_fee_bps:2d}bps retail={retail_fee_bps:2d}bps "
            f"arb_mult={arb_mult_x10/10:.1f}x decay={decay_pct:2d}% "
            f"→ edge={avg_edge:.2f}  (best={best_edge:.2f} @ {best_params})"
        )

        return -avg_edge  # minimize negative edge = maximize edge

    except Exception as e:
        print(f"  [{eval_count}] ERROR: {e}")
        return 0.0


# ──────────────── Parameter bounds ────────────────
# [max_fee_bps, retail_fee_bps, arb_mult_x10, decay_pct]
bounds = [
    (30, 50),    # max_fee_bps: 30-50 (user constraint: ≤50)
    (20, 50),    # retail_fee_bps: 20-50
    (12, 30),    # arb_mult_x10: 1.2x - 3.0x
    (10, 90),    # decay_pct: 10%-90% per step
]

print("=" * 70)
print("OPTIMIZING ADAPTIVE FEE STRATEGY")
print(f"  Bounds: {bounds}")
print(f"  Simulations per eval: {N_SIMS}")
print("=" * 70)

t0 = time.time()

result = differential_evolution(
    evaluate,
    bounds,
    seed=42,
    maxiter=8,       # keep runtime reasonable (~40 evals)
    popsize=5,       # small population for speed
    tol=0.5,         # early stop if converging
    mutation=(0.5, 1.5),
    recombination=0.8,
    polish=False,    # skip polishing (noisy objective)
    disp=True,
)

elapsed = time.time() - t0
print("\n" + "=" * 70)
print(f"OPTIMIZATION COMPLETE in {elapsed:.0f}s ({eval_count} evaluations)")
print(f"Best edge: {-result.fun:.2f}")
print(f"Best params: max_fee={int(round(result.x[0]))}bps, "
      f"retail_fee={int(round(result.x[1]))}bps, "
      f"arb_mult={int(round(result.x[2]))/10:.1f}x, "
      f"decay={int(round(result.x[3]))}%")
print("=" * 70)
