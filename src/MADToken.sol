// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mutually Assured Destruction (MAD)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 MAD (18 decimals) is
/// minted once, in the constructor, to the deployer. There is no owner, no minter, no pause,
/// no blacklist and no fee: after deployment nobody holds any power over the token or over any
/// holder's balance, and the supply can never grow.
/// @dev The deployer is `msg.sender` of the creation transaction. On an IdentityMD launch that is
/// the ProjectFactory, which then distributes the supply (swarm share, pool seed, remainder) itself.
/// The constructor takes no arguments and makes no external calls, so it deploys on an empty chain.
contract MADToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "Mutually Assured Destruction";

    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "MAD";

    /// @notice Decimals of the token. Fixed at 18, the ERC-20 default.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The total and permanent supply: 1,000,000,000 whole tokens in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints the whole fixed supply to the deployer.
    /// @dev Emits a single `Transfer(address(0), msg.sender, TOTAL_SUPPLY)`. Nothing can mint again:
    /// the contract exposes no function that reaches `_mint` after construction.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
