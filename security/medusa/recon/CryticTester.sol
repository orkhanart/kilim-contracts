// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CryticAsserts} from "../lib/chimera/src/CryticAsserts.sol";
import {TargetFunctions} from "./TargetFunctions.sol";

/// @notice Medusa's target: `medusa fuzz --config security/medusa/medusa.json` (see ../README.md).
///         Assertion failures (t/eq) are panics Medusa reports; `property_*` functions are checked after
///         every call.
contract CryticTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
