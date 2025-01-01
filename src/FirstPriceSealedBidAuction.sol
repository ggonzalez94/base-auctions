// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseSealedBidAuction.sol";

/**
 * @title FirstPriceSealedBidAuction
 * @notice An abstract contract for a first-price sealed-bid auction.
 *         In this format, the highest bidder pays their own bid.
 * @dev
 *  - Child contracts must still override `_transferAssetToWinner()` and `_returnAssetToSeller()` for handling the
 *  transfer of the specific asset.
 *  - Bids below the reserve price do not produce a winner.
 */
abstract contract FirstPriceSealedBidAuction is BaseSealedBidAuction {
    /// @dev The highest bid in the auction
    uint96 private highestBid;

    /**
     * @param _seller The address of the seller
     * @param _startTime The block timestamp at which the auction starts
     * @param _commitDeadline No commits allowed after this time
     * @param _revealDeadline No reveals allowed after this time
     * @param _reservePrice The minimum acceptable price
     */
    constructor(
        address _seller,
        uint256 _startTime,
        uint256 _commitDeadline,
        uint256 _revealDeadline,
        uint96 _reservePrice
    ) BaseSealedBidAuction(_seller, _startTime, _commitDeadline, _revealDeadline) {
        highestBid = _reservePrice;
    }

    /**
     * @dev Checks if the amount is higher than the current highest bid and updates the state accordingly.
     *      In the unlikely case of a tie, the first bidder to reveal wins.
     *      If this is not the highest bid, return the collateral to the bidder since they cannot win the auction.
     * @inheritdoc BaseSealedBidAuction
     */
    function _handleRevealedBid(address bidder, uint96 amount) internal virtual override {
        if (amount > highestBid) {
            highestBid = amount;
            currentWinner = bidder;
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
        // If there are no revealed bids above the reserve price, return 0
        if (currentWinner == address(0)) {
            return 0;
        }
        return highestBid;
    }
}
