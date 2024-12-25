// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseSealedBidAuction.sol";

/**
 * @title SecondPriceSealedBidAuction
 * @notice An abstract contract for a second-price sealed-bid auction(Vickrey Auction).
 *         In this format, the highest bidder pays the second-highest bid(or the reserve price if there are no two bids above the reserve price).
 * @dev
 *  - Child contracts must still override `_transferAssetToWinner()` and `_returnAssetToSeller()` for handling the transfer of the specific asset.
 *  - Bids below the reserve price do not produce a winner.
 */
abstract contract SecondPriceSealedBidAuction is BaseSealedBidAuction {
    /// @dev The highest bid in the auction
    uint96 private highestBid;

    /// @dev The second-highest bid in the auction
    uint96 private secondHighestBid;

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
        secondHighestBid = _reservePrice;
    }

    /**
     * @dev Checks if the amount is higher than the current highest bid and updates the state accordingly
     *      In the unlikely case of a tie, the first bidder to reveal wins.
     *      If this is not the highest bid, return the collateral to the bidder since they cannot win the auction.
     * @inheritdoc BaseSealedBidAuction
     */
    function _handleRevealedBid(address bidder, uint96 amount) internal virtual override {
        uint96 currentHighestBid = highestBid;
        // If the bid is the new highest bid, update highestBid and currentWinner, but also move the old highest bid to secondHighestBid
        if (amount > currentHighestBid) {
            highestBid = amount;
            currentWinner = bidder;
            secondHighestBid = currentHighestBid;
        } else {
            // If the bid is higher than the second-highest bid, we update the second-highest bid
            if (amount > secondHighestBid) {
                secondHighestBid = amount;
            }
            // And we return the collateral to the bidder, since they are not running to win the auction anyways
            bids[bidder].collateral = 0;
            (bool success,) = payable(bidder).call{value: amount}("");
            require(success, "Withdraw failed");
        }
    }

    /**
     * @dev Computes the final price after the reveal phase ends.
     *      In a second-price auction, the winner pays the second-highest bid.
     * @return finalPrice The amount the winner pays (0 if no winner)
     */
    function _computeFinalPrice() internal virtual override returns (uint96) {
        // If there are no revealed bids above the reserve price, return 0
        if (currentWinner == address(0)) {
            return 0;
        }
        return secondHighestBid;
    }
}
