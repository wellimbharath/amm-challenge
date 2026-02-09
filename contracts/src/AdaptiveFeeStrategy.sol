// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Adaptive Fee Strategy
/// @notice Max fee 50bps. Uses asymmetric bid/ask after detecting arb.
///         After arb bought X (price pushed down), retail likely sells X →
///         lower bid fee to attract that retail, keep ask at 50bps.
///         After arb sold X, retail likely buys X → lower ask, keep bid at 50.
contract Strategy is AMMStrategyBase {
    uint256 constant SLOT_BID = 0;
    uint256 constant SLOT_ASK = 1;
    uint256 constant SLOT_EMA_SIZE = 2;
    uint256 constant SLOT_LAST_DIR = 3;
    uint256 constant SLOT_CONSEC = 4;

    uint256 constant MAX_FEE_CAP = 50 * BPS;
    // Optimizer-found params (differential evolution, 40 evals, 30 sims each)
    uint256 constant RETAIL_FEE = 49 * BPS;  // barely dip — optimizer says stay near ceiling

    uint256 constant ALPHA = WAD / 5;
    uint256 constant ONE_MINUS_ALPHA = WAD - ALPHA;
    uint256 constant ARB_MULT = 26 * WAD / 10;  // 2.6x EMA threshold

    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        slots[SLOT_BID] = MAX_FEE_CAP;
        slots[SLOT_ASK] = MAX_FEE_CAP;
        slots[SLOT_EMA_SIZE] = WAD / 100;
        return (MAX_FEE_CAP, MAX_FEE_CAP);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 sizeRatio = wdiv(trade.amountY, trade.reserveY);

        // Update EMA
        uint256 ema = slots[SLOT_EMA_SIZE];
        ema = ema == 0 ? sizeRatio : wmul(ALPHA, sizeRatio) + wmul(ONE_MINUS_ALPHA, ema);
        slots[SLOT_EMA_SIZE] = ema;

        // Track consecutive direction
        uint256 dir = trade.isBuy ? 1 : 2;
        uint256 lastDir = slots[SLOT_LAST_DIR];
        uint256 consec = (dir == lastDir) ? slots[SLOT_CONSEC] + 1 : 1;
        slots[SLOT_LAST_DIR] = dir;
        slots[SLOT_CONSEC] = consec;

        // Classify
        bool likelyArb = sizeRatio > wmul(ARB_MULT, ema) || consec >= 3;

        uint256 bidFee;
        uint256 askFee;

        if (likelyArb) {
            // Arb corrected price. Lower fee only on the side retail will use.
            if (trade.isBuy) {
                // Arb bought X → price went down → retail likely sells X (AMM buys X)
                bidFee = RETAIL_FEE;
                askFee = MAX_FEE_CAP;
            } else {
                // Arb sold X → price went up → retail likely buys X (AMM sells X)
                askFee = RETAIL_FEE;
                bidFee = MAX_FEE_CAP;
            }
        } else {
            // Retail just happened → ratchet both back toward ceiling
            uint256 prevBid = slots[SLOT_BID];
            uint256 prevAsk = slots[SLOT_ASK];
            bidFee = prevBid < MAX_FEE_CAP
                ? prevBid + wmul(67 * WAD / 100, MAX_FEE_CAP - prevBid)
                : MAX_FEE_CAP;
            askFee = prevAsk < MAX_FEE_CAP
                ? prevAsk + wmul(67 * WAD / 100, MAX_FEE_CAP - prevAsk)
                : MAX_FEE_CAP;
        }

        // Hard cap
        if (bidFee > MAX_FEE_CAP) bidFee = MAX_FEE_CAP;
        if (askFee > MAX_FEE_CAP) askFee = MAX_FEE_CAP;
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[SLOT_BID] = bidFee;
        slots[SLOT_ASK] = askFee;

        return (bidFee, askFee);
    }

    function getName() external pure override returns (string memory) {
        return "AdaptiveFeeStrategy";
    }
}
