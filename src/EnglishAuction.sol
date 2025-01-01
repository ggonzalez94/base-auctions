// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EnglishAuction
 * @notice Implements a standard English auction mechanism for a single asset, with:
 *         - A reserve price (the minimum bid required to start winning the asset).
 *         - A fixed duration that can be extended if a bid is placed near the end ("anti-sniping" feature).
 *         - Refunds for outbid participants.
 *         - Extensible hooks and internal functions allowing you to customize increments,
 *           whitelists, and how the asset is transferred.
 *
 * @dev
 * This contract is designed to be inherited and extended.
 * - Optional anti-sniping mechanism: If a bid arrives close to the end, the auction is extended.
 *   If you don't want to extend the auction in the case of a last minute bid, set the `extensionThreshold` or
 *  `extensionPeriod` to 0.
 *
 * To use this contract, you must:
 * 1. Provide an implementation of `_transferAssetToWinner(address winner)` that transfers the
 *    auctioned asset (e.g., an NFT) to the auction winner.
 * 2. Provide an implementation of `_transferAssetToSeller()` that transfers the auctioned asset (e.g., an NFT) to the
 *    seller in case there's no winner of the auction.
 * 3. Optionally override `_beforeBid` or `_afterBid` to implement custom bidding logic such as
 *    whitelisting or additional checks.
 * 4. Optionally override `_validateBidIncrement` if you want to require a certain increment over the previous highest
 * bid.
 *
 * If no valid bids are placed above the reserve price by the time the auction ends, anyone can simply finalize the
 * auction and the asset will be returned to the seller.
 */
abstract contract EnglishAuction {
    /// @dev The address of the item’s seller
    address internal immutable seller;

    /// @dev Timestamp (in seconds) at which the auction starts
    uint256 internal immutable startTime;

    /// @dev Timestamp (in seconds) at which the auction ends
    uint256 private endTime;

    /// @dev The current highest bid amount
    ///      This is set to the reserve price at constuction time
    uint256 private highestBid;

    /// @dev The address of the highest bidder
    address private highestBidder;

    /// @dev Indicates if the auction has been finalized
    bool private finalized;

    /// @dev Mapping of addresses to refunds they can withdraw (due to being outbid).
    mapping(address bidder => uint256 amount) private refunds;

    // -------------------------
    // Anti-Sniping Variables (https://en.wikipedia.org/wiki/Auction_sniping)
    // -------------------------

    /// @dev If a bid is placed within `extensionThreshold` seconds of the endTime,
    ///         the auction endTime is extended by `extensionPeriod` seconds.
    ///         If you don't want to extend the auction in the case of a last minute bid, set this to 0.
    ///         But it is highly recommended to have some extension period, as it will discourage last minute sniping.
    uint256 private immutable extensionThreshold;
    uint256 private immutable extensionPeriod;

    /// @dev Accumulated proceeds for the seller to withdraw after finalization.
    uint256 private sellerProceeds;

    /// @notice Emitted when the auction starts.
    /// @param seller The address of the seller.
    /// @param reservePrice The initial reserve price.
    /// @param endTime The scheduled end time of the auction.
    event AuctionCreated(address indexed seller, uint256 reservePrice, uint256 startTime, uint256 endTime);

    /// @notice Emitted when a new highest bid is placed.
    /// @param bidder The address of the new highest bidder.
    /// @param amount The amount of the bid.
    event NewHighestBid(address indexed bidder, uint256 amount);

    /// @notice Emitted when the auction is finalized.
    /// @param winner The address of the winner (highest bidder).
    /// @param amount The winning bid amount.
    event AuctionFinalized(address indexed winner, uint256 amount);

    /// @notice Emitted when a refund becomes available for a previously outbid bidder.
    /// @param bidder The address that can withdraw the refund.
    /// @param amount The amount of the refund.
    event RefundAvailable(address indexed bidder, uint256 amount);

    /// @notice Emitted when funds (refunds or seller proceeds) are withdrawn.
    /// @param recipient The address that received the withdrawn funds.
    /// @param amount The amount withdrawn.
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    /// @notice Emitted when the auction is extended due to a last-minute bid.
    /// @param newEndTime The new end time of the auction.
    event AuctionExtended(uint256 newEndTime);

    /// @dev Thrown when trying to perform an action on an already finalized auction
    error AuctionAlreadyFinalized();

    /// @dev Thrown when trying to perform an action that requires a finalized auction
    error AuctionNotYetFinalized();

    /// @dev Thrown when trying to place a bid after the auction time has ended
    error AuctionEnded();

    /// @dev Thrown when trying to finalize an auction before its end time
    error AuctionNotYetEnded();

    /// @dev Thrown when a bid is not higher than the current highest bid
    /// @param bid The bid amount that was too low
    /// @param highestBid The current highest bid amount
    error BidNotHighEnough(uint256 bid, uint256 highestBid);

    /// @dev Thrown when trying to perform an action before the auction has started
    error AuctionNotStarted();

    /// @dev Thrown when trying to create an auction with zero duration
    error InvalidDuration();

    /// @dev Thrown when trying to create an auction with a start time in the past
    error InvalidStartTime();

    /// @dev Thrown when trying to create an auction with a seller address of zero
    error InvalidSeller();

    /// @dev Auction is considered ongoing during [startTime, endTime)
    modifier auctionOngoing() {
        if (block.timestamp < startTime) revert AuctionNotStarted();
        if (block.timestamp > endTime) revert AuctionEnded();
        _;
    }

    /**
     * @notice Creates a new English auction.
     * @param _seller The address of the seller.
     * @param _reservePrice The reserve price that must be met or exceeded for the auction to produce a sale.
     * @param _startTime The timestamp (in seconds) at which the auction starts.
     * @param _duration The duration (in seconds) from now until the auction ends.
     * @param _extensionThreshold If a bid is placed within this many seconds of the end, time is extended.
     * @param _extensionPeriod How many seconds to extend the auction by when triggered.
     */
    constructor(
        address _seller,
        uint256 _reservePrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _extensionThreshold,
        uint256 _extensionPeriod
    ) {
        if (_seller == address(0)) revert InvalidSeller();
        if (_startTime < block.timestamp) revert InvalidStartTime();
        if (_duration == 0) revert InvalidDuration();

        seller = _seller;
        highestBid = _reservePrice;
        startTime = _startTime;
        endTime = _startTime + _duration;
        extensionThreshold = _extensionThreshold;
        extensionPeriod = _extensionPeriod;

        emit AuctionCreated(seller, highestBid, startTime, endTime);
    }

    // -------------------------
    // Public / External Functions
    // -------------------------

    /**
     * @notice Place a bid higher than the current highest bid, respecting the reserve price.
     * @dev Uses a withdrawal pattern for previous highest bidder refunds.
     *      This means that withdraws for other bidders are not executed automatically.
     *
     * @custom:hook `_beforeBid` and `_afterBid` can be overridden for custom logic.
     */
    function placeBid() external payable virtual auctionOngoing {
        _beforeBid(msg.sender, msg.value);

        _validateBidIncrement(msg.value);

        // Move the old highest bid into a refundable balance
        if (highestBidder != address(0)) {
            refunds[highestBidder] += highestBid;
            emit RefundAvailable(highestBidder, highestBid);
        }

        // Update highest bid
        highestBid = msg.value;
        highestBidder = msg.sender;

        // Anti-sniping: if we're close to the end, extend the auction
        _maybeExtendAuction();

        _afterBid(msg.sender, msg.value);

        emit NewHighestBid(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw refunds owed to the caller due to being outbid.
     * @dev Reverts if no refund is available.
     */
    function withdrawRefund() external {
        uint256 amount = refunds[msg.sender];
        refunds[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Sends proceeds to the seller after the auction has been finalized.
     * @dev Since `sellerProceeds` is only incremented when the auction is finalized, there's no need to check the
     * status of the auction here.
     *      Override to implement custom logic if necessary (e.g. sending the funds to a different address or burning
     * them)
     *      When overriding, make sure to reset the sellerProceeds to 0 and add necessary access control.
     */
    function withdrawSellerProceeds() external virtual {
        uint256 amount = sellerProceeds;
        sellerProceeds = 0;

        (bool success,) = payable(seller).call{value: amount}("");
        require(success, "Transfer failed");
        emit FundsWithdrawn(seller, amount);
    }

    /**
     * @notice Finalizes the auction after it ends, transfering the asset to the winner and allowing the seller to
     * withdraw the highest bid.
     * @dev Anyone can call this after the auction has ended.
     *      If no valid bids above the reserve were placed, no transfer occurs and sellerProceeds remains zero.
     *      You need to override `_transferAssetToWinner` to implement the asset transfer logic.
     *      Funds are not transferred automatically to the seller, they need to call `withdrawSellerProceeds`.
     */
    function finalizeAuction() external virtual {
        if (finalized) revert AuctionAlreadyFinalized();
        if (block.timestamp <= endTime) revert AuctionNotYetEnded();

        finalized = true;

        if (highestBidder != address(0)) {
            // Allow the seller to withdraw the highest bid
            sellerProceeds += highestBid;
            // Transfer asset to the winner
            _transferAssetToWinner(highestBidder);
        } else {
            // Allow the seller to withdraw the asset that was locked in the contract
            _transferAssetToSeller();
        }

        emit AuctionFinalized(highestBidder, highestBid);
    }

    // -------------------------
    // Public View Functions
    // -------------------------

    /**
     * @notice Gets the scheduled start time of the auction.
     * @return The timestamp in seconds at which the auction starts.
     */
    function getStartTime() public view returns (uint256) {
        return startTime;
    }

    /**
     * @notice Gets the scheduled end time of the auction.
     * @return The timestamp in seconds at which the auction ends.
     */
    function getEndTime() public view returns (uint256) {
        return endTime;
    }

    /**
     * @notice Gets the current highest bid.
     * @return The amount of the highest bid.
     */
    function getHighestBid() public view returns (uint256) {
        return highestBid;
    }

    /**
     * @notice Gets the current highest bidder.
     * @return The address of the highest bidder.
     */
    function getHighestBidder() public view returns (address) {
        return highestBidder;
    }

    /**
     * @notice Checks if the auction has been finalized.
     * @return True if finalized, false otherwise.
     */
    function isFinalized() public view returns (bool) {
        return finalized;
    }

    // -------------------------
    // Internal hooks
    // -------------------------

    /**
     * @dev Hook that runs before a bid is processed.
     *      Override to implement custom checks (e.g. whitelists, paused states, etc).
     *      By default, does nothing.
     * @param bidder The address placing the bid.
     * @param amount The amount of the bid.
     */
    function _beforeBid(address bidder, uint256 amount) internal virtual {
        // No-op: override to implement custom checks (e.g. whitelists, pause checks)
    }

    /**
     * @dev Hook that runs after a bid is processed.
     *      Override to implement custom logic (e.g. token rewards, additional event logging).
     *      By default, does nothing.
     * @param bidder The address that placed the bid.
     * @param amount The amount of the bid.
     */
    function _afterBid(address bidder, uint256 amount) internal virtual {
        // No-op: override to implement custom logic after bidding
    }

    /**
     * @dev Checks if the provided bid meets the increment requirements.
     *      By default, requires bid > highestBid.
     *      Override to impose specific increments (e.g. 5% higher than current highestBid).
     *      ```solidity
     *       function _validateBidIncrement(uint256 newBid) internal view override {
     *           uint256 currentHighest = getHighestBid();
     *            if (newBid <= currentHighest * 105 / 100) {
     *               revert BidNotHighEnough(newBid, currentHighest))
     *           }
     *       }
     *      ```
     *      Requiring specific increments can help prevent gas wars, where there's a bidder
     *      that just slightly increments the bid every time.
     */
    function _validateBidIncrement(uint256 newBid) internal view virtual {
        if (newBid <= highestBid) revert BidNotHighEnough(newBid, highestBid);
    }

    /**
     * @dev Extends the auction if a bid is placed near the end.
     *      This helps prevent last minute snipping.
     *      If `endTime - block.timestamp < extensionThreshold`, extend by `extensionPeriod`.
     */
    function _maybeExtendAuction() internal {
        uint256 timeLeft = endTime - block.timestamp;
        if (timeLeft < extensionThreshold && extensionPeriod > 0) {
            endTime += extensionPeriod;
            emit AuctionExtended(endTime);
        }
    }

    /**
     * @dev Internal hook that MUST be overridden by the implementing contract to handle
     *      the transfer of assets (e.g., NFTs, custom digital assets) to the auction winner.
     *      This function is called during auction finalization.
     * @param winner The address of the highest bidder who won the auction
     * @custom:example
     *      function _transferAssetToWinner(address winner) internal override {
     *          nft.transferFrom(address(this), winner, tokenId);
     *      }
     */
    function _transferAssetToWinner(address winner) internal virtual;

    /**
     * @dev Internal hook that MUST be overridden by the implementing contract to handle
     *      the transfer of assets (e.g., NFTs, custom digital assets) to the seller in case there's no winner.
     *      This function is called during auction finalization.
     */
    function _transferAssetToSeller() internal virtual;
}
