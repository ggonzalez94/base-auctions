// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseSealedBidAuction.sol";

/**
 * @title FirstPriceSealedBidAuction
 * @notice An abstract contract for a first-price sealed-bid auction.
 *         In this format, the highest bidder pays their own bid.
 * @dev
 *  - The state variables `highestBid` and `highestBidder` are inherited from `BaseSealedBidAuction`.
 *  - Child contracts must still override `_transferAssetToWinner()` and `_returnAssetToSeller()` for actual asset handling.
 *  - Bids below the reserve price do not produce a winner.
 */
abstract contract FirstPriceSealedBidAuction is BaseSealedBidAuction {
    /**
     * @dev Checks if the amount is higher than the current highest bid and updates the state accordingly
     *      If this is not the highest bid, return the collateral to the bidder
     * @inheritdoc BaseSealedBidAuction
     */
    function _handleRevealedBid(address bidder, uint96 amount) internal virtual override {
        if (amount > highestBid) {
            highestBid = amount;
            highestBidder = bidder;
        } else {
            bids[bidder].collateral = 0;
            (bool success,) = payable(bidder).call{value: amount}("");
            require(success, "Withdraw failed");
        }
    }

    /**
     * @dev Computes the final price after the reveal phase ends.
     *      In a first-price auction, the winner pays exactly their own highest bid.
     * @return finalPrice The amount the winner pays (0 if no winner)
     */
    function _computeFinalPrice() internal virtual override returns (uint96) {
        // If there are no bids, return 0
        // The highest bid should be at least equal to the reserve price(we set it at construct time in the base contract)
        if (highestBid <= reservePrice) {
            return 0;
        }
        return highestBid;
    }
}
