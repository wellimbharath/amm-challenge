// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Adaptive Fee Strategy
/// @notice Stays at a base fee of ~50bps. After detecting retail trades
///         (which push price away from fair value), spikes fees to protect
///         against imminent arb. After arb corrects price, decays back to base.
///         Never drops below base — arb protection always on.
contract Strategy is AMMStrategyBase {
    uint256 constant SLOT_FEE = 0;
    uint256 constant SLOT_EMA_SIZE = 1;
    uint256 constant SLOT_LAST_DIR = 2;
    uint256 constant SLOT_CONSEC = 3;

    uint256 constant BASE_FEE = 50 * BPS;   // resting fee — matches best static
    uint256 constant SPIKE_FEE = 80 * BPS;  // after retail → arb incoming

    uint256 constant ALPHA = WAD / 5;
    uint256 constant ONE_MINUS_ALPHA = WAD - ALPHA;
    uint256 constant ARB_MULT = 18 * WAD / 10;

    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        slots[SLOT_FEE] = BASE_FEE;
        slots[SLOT_EMA_SIZE] = WAD / 100;
        return (BASE_FEE, BASE_FEE);
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

        // After arb → decay toward base (price is corrected)
        // After retail → spike fees (arb coming next)
        uint256 prevFee = slots[SLOT_FEE];
        uint256 fee;

        if (likelyArb) {
            // Decay toward base: drop 30% of distance per step
            if (prevFee > BASE_FEE) {
                uint256 gap = prevFee - BASE_FEE;
                fee = prevFee - wmul(3 * WAD / 10, gap);
            } else {
                fee = BASE_FEE;
            }
        } else {
            // Retail → spike. Scale by how large the retail trade was
            uint256 sizeScale = wdiv(sizeRatio, ema);
            if (sizeScale > WAD) {
                // Above-average retail → full spike
                fee = SPIKE_FEE;
            } else {
                // Small retail → moderate bump
                fee = BASE_FEE + wmul(sizeScale, SPIKE_FEE - BASE_FEE);
            }
        }

        fee = clampFee(fee);
        if (fee < BASE_FEE) fee = BASE_FEE; // never below base
        slots[SLOT_FEE] = fee;

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "AdaptiveFeeStrategy";
    }
}
