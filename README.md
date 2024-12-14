# On-Chain Auctions Library

*Modular, extensible and well documented auctions written in Solidity*

## Why Auctions Matter in Web3?

Auctions are a core mechanism for determining fair market prices, allocating scarce digital assets, and fostering open participation. In web3, trustless, on-chain auctions bring transparency, security, and efficiency—empowering anyone, anywhere to participate without intermediaries.  
Auctions are everywhere in web3, from NFT sales to MEV, but there's no library that provides teams with base implementations they can extend.

## Current Implementations

* [English Auction](src/EnglishAuction.sol): A classic ascending-price auction that allows bids until a deadline and extends time to prevent last-second sniping. Built with extensibility hooks for custom increments, bidder whitelists, and unique asset-transfer logic.

## Installation

### Foundry

```bash
forge install ggonzalez94/base-auctions
```

Add `@base-auctions/=lib/base-auctions/src/` in `remappings.txt`.

## Usage

Once installed, you can use the contracts in the library by importing them:

```solidity
pragma solidity ^0.8.20;

import {EnglishAuction} from "@base-auctions/EnglishAuction.sol";

contract MyAuction is EnglishAuction {
    address public winnerAssetRecipient;

    constructor(
        address _seller,
        uint256 _reservePrice,
        uint256 _duration,
        uint256 _extensionThreshold,
        uint256 _extensionPeriod
    ) EnglishAuction(_seller, _reservePrice, _duration, _extensionThreshold, _extensionPeriod) {}

    // Here you would normally transfer the actual asset to the winner(e.g. the NFT)
    function _transferAssetToWinner(address winner) internal override {
        winnerAssetRecipient = winner;
    }
}
```

## Contributing

We welcome contributions from the community! If you have ideas for new auction types, improvements to the existing code, or better tooling and documentation, please open an issue or submit a PR.

## Roadmap

These are some of the next auctions we plan to implement, but it's very early and we're open to suggestions.

* [ ] Dutch Auction
* [ ] Sealed-Bid Auction
* [ ] Vickrey Auction (Second-Price Sealed-Bid Auction)
* [ ] Reverse Auction
* [ ] All-pay auction (also known as a Tullock contest)

## Disclaimer

This code has not been audited and is provided "as is". While we've taken care to write well-documented, secure code, you use this software at your own risk.
