// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Combined Directional + Widen Strategy
/// @notice Merges two concepts:
///   1. Widen after big trades: bump fees up when a large trade hits, decay back otherwise
///   2. Directional asymmetry: after a price move, penalize continuation and reward reversal
contract Strategy is AMMStrategyBase {
    // slots[0] = symmetric base fee level (adapts via widen/decay)
    // slots[1] = last price (WAD)

    uint256 constant STARTING_FEE = 80 * BPS;  // 80 bps starting fee
    uint256 constant MIN_BASE = 60 * BPS;       // decay floor
    uint256 constant WIDEN_AMOUNT = 15 * BPS;   // bump on big trades
    uint256 constant DECAY_AMOUNT = 1 * BPS;    // decay per small trade
    uint256 constant BIG_TRADE_THRESHOLD = WAD / 20; // 5% of reserves
    uint256 constant C = 2e16;                  // 0.02 directional adjustment

    function afterInitialize(uint256 initialX, uint256 initialY)
        external override returns (uint256, uint256)
    {
        slots[0] = STARTING_FEE;
        slots[1] = wdiv(initialY, initialX);
        return (STARTING_FEE, STARTING_FEE);
    }

    function afterSwap(TradeInfo calldata trade)
        external override returns (uint256, uint256)
    {
        uint256 baseFee = slots[0];
        uint256 lastPrice = slots[1];

        // --- Widen / Decay ---
        uint256 tradeRatio = wdiv(trade.amountY, trade.reserveY);
        if (tradeRatio > BIG_TRADE_THRESHOLD) {
            baseFee = clampFee(baseFee + WIDEN_AMOUNT);
        } else {
            if (baseFee > MIN_BASE) {
                baseFee = baseFee - DECAY_AMOUNT;
            }
        }

        // --- Directional Asymmetry ---
        uint256 currentPrice = wdiv(trade.reserveY, trade.reserveX);
        uint256 bidFee = baseFee;
        uint256 askFee = baseFee;

        if (currentPrice > lastPrice) {
            uint256 delta = wdiv(currentPrice - lastPrice, lastPrice);
            uint256 adj = wmul(C, delta);
            askFee = clampFee(baseFee + adj);
            bidFee = adj >= baseFee ? 0 : baseFee - adj;
        } else if (currentPrice < lastPrice) {
            uint256 delta = wdiv(lastPrice - currentPrice, lastPrice);
            uint256 adj = wmul(C, delta);
            bidFee = clampFee(baseFee + adj);
            askFee = adj >= baseFee ? 0 : baseFee - adj;
        }

        // --- Store state ---
        slots[0] = baseFee;
        slots[1] = currentPrice;

        return (bidFee, askFee);
    }

    function getName() external pure override returns (string memory) {
        return "DirectionalWiden";
    }
}
