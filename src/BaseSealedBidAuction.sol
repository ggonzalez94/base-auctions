// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BaseSealedBidAuction
 * @notice A base contract for sealed-bid auctions with a commit-reveal scheme and over-collateralization.
 *         Each user has exactly one active bid, which can be overwritten (topped up) before `commitDeadline`.
 *         It is recommended to use one of the child contracts(`FirstPriceSealedBidAuction` or `SecondPriceSealedBidAuction`) instead
 *         of using this contract directly, as they implement the logic for determining the winner, final price, and update the contract state accordingly.
 * @dev
 *  Privacy is achieved by hashing the commit and allowing overcollaterilzation.
 *  The contract ensure bidders commit(are not able to back out of their bid) by taking custody fo the funds.
 *  The contract ensures that bidders always reveal their bids, otherwise their funds are stuck(this can be customized by overriding `_checkWithdrawal`)
 *  - Bidder commits by providing a `commitHash` plus some ETH collateral >= intended bid.
 *  - If they want to raise or change their hidden bid, they call `commitBid` again with a new hash, sending more ETH.
 *  - During reveal, user reveals `(salt, amount)`. If `collateral < amount`, reveal fails.
 *  - Child contracts handle final pricing logic (first-price or second-price).
 *  - This design is heavily inspired by [OverCollateralizedAuction from a16z](https://github.com/a16z/auction-zoo/blob/main/src/sealed-bid/over-collateralized-auction/OverCollateralizedAuction.sol)
 */
abstract contract BaseSealedBidAuction is ReentrancyGuard {
    /// @dev The address of the seller or beneficiary
    address private immutable seller;

    /// @dev The block timestamp at which the auction starts
    uint256 private immutable startTime;

    /// @dev The block timestamp after which no new commits can be made
    uint256 private immutable commitDeadline;

    /// @dev The block timestamp after which no new reveals can be made
    uint256 private immutable revealDeadline;

    /// @dev The minimum price required to win (reserve price)
    uint96 private immutable reservePrice;

    /// @dev Info about one bidder’s commit
    /// @param commitHash The hash commitment of a bid value
    ///        WARNING: The hash is truncated to 20 bytes (160 bits) to save one
    ///        storage slot. This weakens the security, and it is theoretically
    ///        feasible to generate two bids with different values that hash to
    ///        the same 20-byte value (check a16z repo for more details:
    ///        https://github.com/a16z/auction-zoo/issues/2). This would allow a
    ///        bidder to effectively withdraw their bid at the last minute, once
    ///        other bids have been revealed. Currently, the computational cost of
    ///        such an attack would likely be prohibitvely high –– as of June 2021,
    ///        researchers estimated that finding such a collision would cost ~$10B.
    ///        If computational costs falls to the extent that this attack is a
    ///        concern, it is possible to further mitigate the possibility of such
    ///        an attack by using the full 32-byte hash value for the bid commitment.
    /// @param collateral The amount of collateral backing the bid.
    struct BidInfo {
        bytes20 commitHash; // keccak256(abi.encode(...)) representing their sealed bid
        uint96 collateral; // must be >= hidden bid
    }

    /// @dev Per-user single bid storage
    mapping(address => BidInfo) private bids;

    // -------------------------
    // Auction state(common across all sealed bid auctions)
    // -------------------------
    uint96 internal highestBid;
    address internal highestBidder;
    uint64 internal numUnrevealedBids;

    /// @notice Emitted when a bidder reveals their bid during the reveal phase
    /// @param bidder The address of the bidder who revealed their bid
    /// @param bidAmount The amount of the revealed bid
    event BidRevealed(address indexed bidder, uint96 bidAmount);

    /// @notice Emitted when the auction ends, either after all bids are revealed or after the reveal deadline
    /// @param winner The address of the winning bidder (address(0) if no valid winner)
    /// @param finalPrice The final price paid by the winner (determined by auction type - first price or second price)
    event AuctionEnded(address indexed winner, uint96 finalPrice);

    /// @notice Emitted when a bidder withdraws their remaining collateral
    /// @param bidder The address of the bidder withdrawing their collateral
    /// @param amount The amount of collateral withdrawn
    event CollateralWithdrawn(address indexed bidder, uint96 amount);

    /// @dev Thrown when trying to commit a bid outside of the commit phase
    error NotInCommitPhase();

    /// @dev Thrown when trying to reveal a bid outside of the reveal phase
    error NotInRevealPhase();

    /// @dev Thrown when trying to reveal a bid that doesn't exist or has already been revealed
    error NoBidCommitted();

    /// @dev Thrown when the provided collateral is insufficient for the bid amount
    /// @param given The amount of collateral provided
    /// @param required The minimum amount of collateral needed
    error InvalidCollateral(uint96 given, uint96 required);

    /// @dev Thrown when the commitment hash is invalid (empty or doesn't match during reveal)
    error InvalidCommitment();

    /// @dev Thrown when attempting to set the seller address to zero
    error InvalidSeller();

    /// @dev Thrown when commit deadline is not before reveal deadline
    error InvalidCommitRevealDeadlines();

    /// @dev Thrown when start time is invalid (must be in future and before commit deadline)
    error InvalidStartTime();

    /// @dev Thrown when trying to end auction before reveal deadline with unrevealed bids
    error NotReadyToEnd();

    /// @dev Thrown when trying to withdraw collateral for an unrevealed bid
    error UnrevealedBidError();

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
    ) {
        if (_seller == address(0)) revert InvalidSeller();
        if (_commitDeadline >= _revealDeadline) revert InvalidCommitRevealDeadlines();
        if (_startTime <= block.timestamp || _startTime >= _commitDeadline) revert InvalidStartTime();

        seller = _seller;
        commitDeadline = _commitDeadline;
        revealDeadline = _revealDeadline;
        reservePrice = _reservePrice;

        // Initialize internal AuctionData with reserve
        highestBid = _reservePrice;
    }

    /**
     * @notice Commit a sealed bid or update an existing commitment with more collateral.
     * @dev It is strongly recommended that salt is a random value, and the bid is overcollateralized to avoid leaking information about the bid value.
     *  - Overwrites the old commitHash with the new one (if any).
     *  - Accumulates the new ETH into user’s collateral.
     * @param commitHash The hash commitment to the bid, computed as
     *                   `bytes20(keccak256(abi.encode(salt, bidValue)))`
     *                   It is strongly recommended that salt is generated offchain, and is a random value, to avoid other actors from guessing the bid value.
     */
    function commitBid(bytes20 commitHash) external payable {
        if (block.timestamp < startTime || block.timestamp > commitDeadline) revert NotInCommitPhase();
        if (commitHash == bytes20(0)) revert InvalidCommitment();

        BidInfo storage bid = bids[msg.sender];

        // If this is the bidders first commit, increase numUnrevealedBids
        if (bid.commitHash == bytes20(0)) {
            numUnrevealedBids++;
        }

        // Overwrite or set the commitHash
        bid.commitHash = commitHash;

        // Increase collateral by msg.value
        bid.collateral += uint96(msg.value);
    }

    /**
     * @notice Reveal the actual bid.
     * @dev This function only validates the amount and salt are correct, and updates the amount of unrevealed bids left.
     *      The logic for determining if the bid is the highest, update the records and handle refunds is handled in the child contract
     *      by implementing the `_handleRevealedBid` function.
     * @param salt Random salt used in commit
     * @param bidAmount The actual bid amount user is paying
     */
    function revealBid(bytes32 salt, uint96 bidAmount) external {
        if (block.timestamp <= commitDeadline || block.timestamp > revealDeadline) {
            revert NotInRevealPhase();
        }

        BidInfo storage bid = bids[msg.sender];
        if (bid.commitHash == bytes20(0)) revert NoBidCommitted();
        if (bid.collateral < bidAmount) revert InvalidCollateral(bid.collateral, bidAmount);

        // Recompute hash
        bytes20 checkHash = bytes20(keccak256(abi.encode(salt, bidAmount)));
        if (checkHash != bid.commitHash) revert InvalidCommitment();

        // Mark commitment as revealed
        bid.commitHash = bytes20(0);
        numUnrevealedBids--;

        // `_handleRevealedBid` should update the internal state such that `highestBidder` and `highestBid` are accurate
        _handleRevealedBid(msg.sender, bidAmount);

        emit BidRevealed(msg.sender, bidAmount);
    }

    /**
     * @notice Ends the auction after the reveal deadline has passed or all bids have been revealed
     * @dev
     *  - Finalizes the winner and final price (child decides first-price or second-price).
     *  - Transfers the asset to the winner or returns it to the seller if no valid winner.
     *  - Pays the seller.
     */
    function endAuction() external nonReentrant {
        if (block.timestamp <= revealDeadline && numUnrevealedBids > 0) revert NotReadyToEnd();

        uint96 finalPrice = _computeFinalPrice();
        address winner = highestBidder;

        // If there's a winner, the final price is necessarily greater than 0
        if (winner != address(0)) {
            // Transfer item
            _transferAssetToWinner(winner);

            // Pay seller
            _withdrawSellerProceeds(finalPrice);
        } else {
            // No valid winner(no bids revealed or none above reserve)
            _returnAssetToSeller();
        }

        emit AuctionEnded(winner, finalPrice);
    }

    /// @notice Allows bidders to withdraw their collateral after revealing their bid
    /// @dev The winner can use this to withdraw excess collateral beyond the final price.
    ///      Bidders must reveal their bid before withdrawing - unrevealed bids result in
    ///      locked collateral to enforce reveal participation. This incentive mechanism
    ///      can be customized by overriding `_checkWithdrawal`.
    function withdrawCollateral() external {
        uint96 amount = _checkWithdrawal(msg.sender);
        bids[msg.sender].collateral = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdraw failed");

        emit CollateralWithdrawn(msg.sender, amount);
    }

    // -------------------------
    // Internal Functions
    // -------------------------

    /**
     * @dev Sends funds to the seller after the auction has been finalized.
     *      Override to implement custom logic if necessary (e.g. sending the funds to a different address or burning them)
     * @param amount The amount of proceeds to withdraw.
     */
    function _withdrawSellerProceeds(uint96 amount) internal virtual {
        (bool success,) = payable(seller).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// @dev Checks if a withdrawal can be performed for `bidder`.
    ///      It requires that the bidder revealed their bid on time and locks the funds in the contract otherwise.
    ///      This is done to incentivize bidders to always reveal, instead of whitholding if they realize they overbid.
    ///      This logic can be customized by overriding this function, to allow for example lock funds to be withdrawn to the seller.
    ///      Or to allow late reveals for bids that were lower than the winner's bid.
    /// @param bidder The address of the bidder to check
    /// @return amount The amount that can be withdrawn
    function _checkWithdrawal(address bidder) internal view virtual returns (uint96) {
        BidInfo storage bid = bids[bidder];
        if (bid.commitHash != bytes20(0)) {
            revert UnrevealedBidError();
        }

        uint96 amount = bid.collateral;
        return amount;
    }

    /**
     * @dev Called when a bidder reveals their bid. MUST be overridden by the implementing contract.
     *      Child contract updates highest, secondHighest, etc.
     * @param bidder The bidder’s address
     * @param amount The revealed bid amount
     */
    function _handleRevealedBid(address bidder, uint96 amount) internal virtual;

    /**
     * @dev Determine the final price. For first-price, it’s the highest bid;
     *      for second-price, it might be secondHighest or max(secondHighest, reserve).
     *      MUST be overridden by the implementing contract to handle the logic for determining the final price.
     */
    function _computeFinalPrice() internal virtual returns (uint96);

    /**
     * @dev Internal hook that MUST be overridden by the implementing contract to handle
     *      the transfer of assets (e.g., NFTs, custom digital assets) to the auction winner.
     *      This function is called during auction finalization.
     */
    function _transferAssetToWinner(address winner) internal virtual;

    /**
     * @dev Internal hook that MUST be overridden by the implementing contract to handle
     *      the transfer of assets (e.g., NFTs, custom digital assets) to the seller in case there's no winner.
     *      This function is called during auction finalization.
     */
    function _returnAssetToSeller() internal virtual;
}
