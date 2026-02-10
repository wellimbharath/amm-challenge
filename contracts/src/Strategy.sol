// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Arb/Retail Discriminator Strategy
/// @notice Uses timestamp tracking to detect whether a trade is likely arb or retail.
/// @dev In each simulation step: arbs trade first, then retail arrives via Poisson.
///      - First trade in a new step (timestamp changed) = likely arb
///      - Subsequent trades in same step (timestamp unchanged) = likely retail
///      After arb: set LOW fees to attract retail that follows in the same step.
///      After retail: set HIGH fees to protect against the arb that opens the next step.
contract Strategy is AMMStrategyBase {
    // slots[0] = last timestamp

    uint256 constant ARB_FEE = 35 * BPS;       // high fee to catch arbs
    uint256 constant RETAIL_FEE = 25 * BPS;     // low fee to attract retail

    function afterInitialize(uint256, uint256)
        external override returns (uint256, uint256)
    {
        // First trade will be arb (step 0), set high fees
        return (ARB_FEE, ARB_FEE);
    }

    function afterSwap(TradeInfo calldata trade)
        external override returns (uint256, uint256)
    {
        uint256 lastTimestamp = slots[0];

        if (trade.timestamp != lastTimestamp) {
            // New step — this trade was the first in this step (likely arb)
            // Set LOW fees for the next trade (likely retail in same step)
            slots[0] = trade.timestamp;
            return (RETAIL_FEE, RETAIL_FEE);
        } else {
            // Same step — this trade was retail
            // Set HIGH fees for the next trade (likely arb in next step)
            return (ARB_FEE, ARB_FEE);
        }
    }

    function getName() external pure override returns (string memory) {
        return "ArbRetailDiscriminator";
    }
}
