// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title DemoBorrower
/// @notice A borrower account for CrashLab's sandbox runs. Only the lab that created it can act for it, so the
///         lab can open identical positions and arm the guard on one of them in a single script.
contract DemoBorrower {
    address public immutable lab;

    error NotLab();

    constructor() {
        lab = msg.sender;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != lab) revert NotLab();
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
