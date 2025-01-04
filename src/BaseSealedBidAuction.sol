// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BaseSealedBidAuction
 * @notice A base contract for sealed-bid auctions with a commit-reveal scheme and over-collateralization.
 *         Each user has exactly one active bid, which can be overwritten (topped up) before `commitDeadline`.
 *         This contract only handles commit-reveal and overcollateralization logic, and can be used with different
 *         auction types.
 *         It is recommended to use one of the child contracts(`FirstPriceSealedBidAuction` or
 *         `SecondPriceSealedBidAuction`) instead
 *         of using this contract directly, as they implement the logic for determining the winner, final price, and
 *         update the contract state accordingly.
 * @dev
 *  Privacy is achieved by hashing the commit and allowing overcollaterilzation.
 *  The contract ensure bidders commit(are not able to back out of their bid) by taking custody of the funds.
 *  The contract ensures that bidders always reveal their bids, otherwise their funds are stuck(this can be customized
 *  by overriding `_checkWithdrawal`)
 *  - Bidder commits by providing a `commitHash` plus some ETH collateral >= intended bid.
 *  - If they want to raise or change their hidden bid, they call `commitBid` again with a new hash, sending more ETH.
 *  - During reveal, user reveals `(salt, amount)`. If `collateral < amount`, reveal fails.
 *  - Child contracts handle final pricing logic (first-price or second-price).
 *  - This design is heavily inspired by [OverCollateralizedAuction from
 * a16z](https://github.com/a16z/auction-zoo/blob/main/src/sealed-bid/over-collateralized-auction/OverCollateralizedAuction.sol)
 */
abstract contract BaseSealedBidAuction is ReentrancyGuard {
    /// @notice The address of the seller or beneficiary
    address internal immutable seller;

    /// @notice The block timestamp at which the auction starts
    uint256 internal immutable startTime;

    /// @notice The block timestamp after which no new commits can be made
    uint256 internal immutable commitDeadline;

    /// @notice The block timestamp after which no new reveals can be made
    uint256 internal immutable revealDeadline;

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
        bytes20 commitHash; // bytes20(keccak256(abi.encode(salt, bidValue))) representing their sealed bid
        uint96 collateral; // must be >= hidden bid
    }

    /// @dev Per-user single bid storage
    mapping(address => BidInfo) internal bids;

    /// @dev The address of the current winner(e.g.highest bidder for a first-price auction)
    address internal currentWinner;

    /// @dev The number of unrevealed bids
    uint64 internal numUnrevealedBids;

    /// @dev Whether the auction has been finalized
    bool internal finalized;

    /// @notice Emitted when a bidder commits their bid during the commit phase
    /// @param bidder The address of the bidder who committed their bid
    /// @param commitHash The hash commitment of the bid
    event BidCommitted(address indexed bidder, bytes20 commitHash);

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

    /// @dev Thrown when trying to withdraw collateral while still in the run to win the auction
    error CannotWithdrawError();

    /// @dev Thrown when commit deadline is not before reveal deadline
    error InvalidCommitRevealDeadlines();

    /// @dev Thrown when start time is invalid (must be in future and before commit deadline)
    error InvalidStartTime();

    /// @dev Thrown when trying to end auction before reveal deadline with unrevealed bids
    error NotReadyToEnd();

    /// @dev Thrown when trying to withdraw collateral for an unrevealed bid
    error UnrevealedBidError();

    /// @dev Thrown when trying to end auction after it has already been finalized
    error AuctionAlreadyFinalized();

    /**
     * @param _seller The address of the seller
     * @param _startTime The block timestamp at which the auction starts
     * @param _commitDeadline No commits allowed after this time
     * @param _revealDeadline No reveals allowed after this time
     */
    constructor(address _seller, uint256 _startTime, uint256 _commitDeadline, uint256 _revealDeadline) {
        if (_seller == address(0)) revert InvalidSeller();
        if (_commitDeadline >= _revealDeadline) revert InvalidCommitRevealDeadlines();
        if (_startTime < block.timestamp || _startTime >= _commitDeadline) revert InvalidStartTime();

        seller = _seller;
        startTime = _startTime;
        commitDeadline = _commitDeadline;
        revealDeadline = _revealDeadline;
    }

    /**
     * @notice Commit a sealed bid or update an existing commitment with more collateral.
     * @dev It is strongly recommended that salt is a random value, and the bid is overcollateralized to avoid leaking
     * information about the bid value.
     *  - Overwrites the old commitHash with the new one (if any).
     *  - Accumulates the new ETH into user’s collateral.
     * @param commitHash The hash commitment to the bid, computed as
     *                   `bytes20(keccak256(abi.encode(salt, bidValue)))`
     *                   It is strongly recommended that salt is generated offchain, and is a random value, to avoid
     * other actors from guessing the bid value.
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

        emit BidCommitted(msg.sender, commitHash);
    }

    /**
     * @notice Reveal the actual bid.
     * @dev This function only validates the amount and salt are correct, and updates the amount of unrevealed bids
     * left.
     *      The logic for determining if the bid is the best(e.g. highest bid for a first-price auction), update the
     * records and handle refunds is handled in the child contract
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

        // `_handleRevealedBid` should update the internal state such that `currentWinner` is accurate
        _handleRevealedBid(msg.sender, bidAmount);

        emit BidRevealed(msg.sender, bidAmount);
    }

    /**
     * @notice Ends the auction after the reveal deadline has passed or all bids have been revealed.
     *         This transfers the asset to the winner, pays the seller, and returns excess collateral to the winner.
     * @dev
     *  - Finalizes the winner and final price (child decides first-price or second-price).
     *  - Transfers the asset to the winner or returns it to the seller if no valid winner.
     *  - Pays the seller.
     */
    function endAuction() external nonReentrant {
        // Avoid this function being called multiple times
        if (finalized) revert AuctionAlreadyFinalized();

        // We allow ending the auction sooner if there are no unrevealed bids, but not before the reveal period.
        if (block.timestamp <= commitDeadline) revert NotReadyToEnd();
        if (block.timestamp <= revealDeadline && numUnrevealedBids > 0) revert NotReadyToEnd();

        finalized = true;

        uint96 finalPrice = _computeFinalPrice();
        address winner = currentWinner;

        if (winner != address(0)) {
            // Transfer item
            _transferAssetToWinner(winner);

            // Pay seller
            _withdrawSellerProceeds(finalPrice);

            // Transfer excess collateral to the winner.
            uint96 excessCollateral = bids[winner].collateral - finalPrice;
            // Not needed since we don't allow the winner to call `withdrawCollateral`, but just to be safe
            bids[winner].collateral = 0;
            if (excessCollateral > 0) {
                // We don't revert if the transfer fails to avoid blocking the auction in the case of a non payable
                // winner contract
                (bool success,) = payable(winner).call{value: excessCollateral}("");
            }
        } else {
            // No valid winner(no bids revealed or none above reserve)
            _returnAssetToSeller();
        }

        emit AuctionEnded(winner, finalPrice);
    }

    /// @notice Withdraws collateral. Bidder must have opened their bid commitment
    ///         and cannot be in the running to win the auction.
    /// @dev Bidders must reveal their bid before withdrawing - unrevealed bids result in
    ///      locked collateral to enforce reveal participation. This incentive mechanism
    ///      can be customized by overriding `_checkWithdrawal`.
    /// @dev The winner of the auction is refunded with any excess collateral when the auction ends by anyone calling
    /// `endAuction()`.
    function withdrawCollateral() external {
        // If `msg.sender` is currently running to win the auction don't allow them to withdraw
        if (msg.sender == currentWinner) {
            revert CannotWithdrawError();
        }

        // Check withdrawal conditions and calculate amount. By default, the bidder must have revealed their bid.
        uint96 amount = _checkWithdrawal(msg.sender);
        bids[msg.sender].collateral = 0;

        if (amount > 0) {
            (bool success,) = payable(msg.sender).call{value: amount}("");
            require(success, "Withdraw failed");
        }

        emit CollateralWithdrawn(msg.sender, amount);
    }

    // -------------------------
    // Internal Functions
    // -------------------------

    /**
     * @dev Sends funds to the seller after the auction has been finalized.
     *      Override to implement custom logic if necessary (e.g. sending the funds to a different address or burning
     * them)
     * @param amount The amount of proceeds to withdraw.
     */
    function _withdrawSellerProceeds(uint96 amount) internal virtual {
        (bool success,) = payable(seller).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// @dev Checks if a withdrawal can be performed for `bidder`.
    ///      - It requires that the bidder revealed their bid on time and locks the funds in the contract otherwise.
    ///        This is done to incentivize bidders to always reveal, instead of withholding if they realize they
    /// overbid.
    ///      This logic can be customized by overriding this function, to allow for example locked funds to be withdrawn
    /// to the seller.
    ///      Or to allow late reveals for bids that were lower than the winner's bid.
    ///      Or to apply a late reveal penalty, but still allow the bidder to withdraw their funds.
    ///      WARNING: Be careful when overrding, as it can create incentives where bidders don't reveal if they realize
    /// they overbid.
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

    // -------------------------
    // Public View Functions
    // -------------------------
    /**
     * @notice Get the seller address
     * @return The address of the seller
     */
    function getSeller() external view returns (address) {
        return seller;
    }

    /**
     * @notice Get the start time of the auction
     * @return The start time of the auction
     */
    function getStartTime() public view returns (uint256) {
        return startTime;
    }

    /**
     * @notice Get the commit deadline of the auction
     * @return The commit deadline of the auction
     */
    function getCommitDeadline() public view returns (uint256) {
        return commitDeadline;
    }

    /**
     * @notice Get the reveal deadline of the auction
     * @return The reveal deadline of the auction
     */
    function getRevealDeadline() public view returns (uint256) {
        return revealDeadline;
    }

    /**
     * @notice Get the finalized state of the auction
     * @return True if the auction is finalized, false otherwise
     */
    function isFinalized() public view returns (bool) {
        return finalized;
    }

    /**
     * @notice Get the bid info for a bidder
     * @param bidder The address of the bidder
     * @return The bid commitment and collateral for the bidder
     */
    function getBid(address bidder) public view returns (BidInfo memory) {
        return bids[bidder];
    }

    // -------------------------
    // Internal hooks
    // -------------------------

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
     * @dev Make sure this function does not revert, as it might lock the auction in a non finalized state
     */
    function _transferAssetToWinner(address winner) internal virtual;

    /**
     * @dev Internal hook that MUST be overridden by the implementing contract to handle
     *      the transfer of assets (e.g., NFTs, custom digital assets) to the seller in case there's no winner.
     *      This function is called during auction finalization.
     * @dev Make sure this function does not revert, as it might lock the auction in a non finalized state
     */
    function _returnAssetToSeller() internal virtual;
}
