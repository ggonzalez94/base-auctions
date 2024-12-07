// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title EnglishAuction
 * @notice Implements a standard English auction with a reserve price and a predefined end time, plus optional anti-sniping time extensions.
 * @dev Designed to be extended. Provides hooks to customize bid validation, increments, and asset transfers.
 */
abstract contract EnglishAuction {
    /// @notice The address of the item’s seller
    address private immutable seller;

    /// @notice The minimum price at which the auction will start
    uint256 private immutable reservePrice;

    /// @notice Timestamp (in seconds) at which the auction ends
    uint256 private endTime;

    /// @notice The current highest bid amount
    uint256 private highestBid;

    /// @notice The address of the highest bidder
    address private highestBidder;

    /// @notice Indicates if the auction has been finalized
    bool private finalized;

    /// @notice Mapping of addresses to refunds they can withdraw
    mapping(address bidder => uint256 amount) private refunds;

    // -------------------------
    // Anti-Sniping Variables (https://en.wikipedia.org/wiki/Auction_sniping)
    // -------------------------

    /// @notice If a bid is placed within `extensionThreshold` seconds of the endTime,
    ///         the auction endTime is extended by `extensionPeriod` seconds.
    ///         If you don't want to extend the auction in the case of a last minute bid, set this to 0.
    ///         But it is highly recommended to have some extension period, as it will discourage sniping.
    uint256 private immutable extensionThreshold;
    uint256 private immutable extensionPeriod;

    event AuctionStarted(address indexed seller, uint256 reservePrice, uint256 endTime);
    event NewHighestBid(address indexed bidder, uint256 amount);
    event AuctionFinalized(address indexed winner, uint256 amount);
    event RefundAvailable(address indexed bidder, uint256 amount);
    event FundsWithdrawn(address indexed recipient, uint256 amount);
    event AuctionExtended(uint256 newEndTime);

    // TODO: Add parameters to the errors where relevant
    error AuctionAlreadyFinalized();
    error AuctionNotYetEnded();
    error AuctionEnded();
    error OnlySellerCanCall();
    error BidNotHighEnough();
    // -------------------------
    // Modifiers
    // -------------------------

    modifier onlySeller() {
        _checkSeller();
        _;
    }

    modifier notFinalized() {
        _checkAuctionNotFinalized();
        _;
    }

    modifier auctionOngoing() {
        _checkAuctionOngoing();
        _;
    }

    modifier auctionEnded() {
        _checkAuctionEnded();
        _;
    }

    /**
     * @param _reservePrice The minimum bid required to start winning
     * @param _duration The number of seconds from now until the auction ends
     * @param _extensionThreshold If a bid is placed within this many seconds of the end, time is extended
     * @param _extensionPeriod How many seconds to extend the auction by when triggered
     */
    constructor(
        address _seller,
        uint256 _reservePrice,
        uint256 _duration,
        uint256 _extensionThreshold,
        uint256 _extensionPeriod
    ) {
        seller = _seller;
        reservePrice = _reservePrice;
        endTime = block.timestamp + _duration;
        extensionThreshold = _extensionThreshold;
        extensionPeriod = _extensionPeriod;

        emit AuctionStarted(seller, reservePrice, endTime);
    }

    // -------------------------
    // Public / External Functions
    // -------------------------

    /**
     * @notice Place a bid higher than the current highest bid, respecting the reserve price.
     * @dev Uses a withdrawal pattern for previous highest bidder refunds.
     *      This function is `virtual` to allow overriding bidding logic.
     */
    function placeBid() external payable virtual auctionOngoing notFinalized {
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
     */
    function withdrawRefund() external {
        uint256 amount = refunds[msg.sender];
        require(amount > 0, "No refund available.");

        refunds[msg.sender] = 0;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Finalizes the auction, transferring funds to the seller and the asset to the winner.
     * @dev This function is `virtual` to allow customization. Anyone can call it after the auction ends.
     */
    function finalizeAuction() external virtual notFinalized auctionEnded {
        finalized = true;

        if (highestBidder != address(0)) {
            // TODO: Should we separate the withdraw of funds to the seller in another function?
            (bool success,) = payable(seller).call{value: highestBid}("");
            require(success, "Transfer failed");

            emit FundsWithdrawn(seller, highestBid);

            // Transfer asset to the winner
            _transferAssetToWinner(highestBidder);
        }

        emit AuctionFinalized(highestBidder, highestBid);
    }

    // -------------------------
    // Internal & Private Functions
    // -------------------------

    /**
     * @dev Hook that runs before a bid is processed.
     *      Useful for additional checks, KYC, whitelisting, or logging.
     *      By default, it does nothing.
     */
    function _beforeBid(address bidder, uint256 amount) internal virtual {
        // No-op: override to implement custom checks (e.g. whitelists, pause checks)
    }

    /**
     * @dev Hook that runs after a bid is processed.
     *      Useful for additional logic like tracking metrics or state.
     */
    function _afterBid(address bidder, uint256 amount) internal virtual {
        // No-op: override to implement custom logic after bidding
    }

    /**
     * @dev Checks if the provided bid meets the increment requirements.
     *      By default, requires bid > highestBid and >= reservePrice.
     *      Override to impose specific increments (e.g. 5% higher than current highestBid).
     */
    function _validateBidIncrement(uint256 newBid) internal view virtual {
        if (newBid <= highestBid || newBid < reservePrice) revert BidNotHighEnough();
    }

    /**
     * @dev Extends the auction if a bid is placed near the end.
     *      If `endTime - block.timestamp < extensionThreshold`, extend by `extensionPeriod`.
     */
    function _maybeExtendAuction() internal {
        // TODO:can we simplify this to:
        // uint256 timeLeft = endTime - block.timestamp; since endTime should always be in the future?
        uint256 timeLeft = endTime > block.timestamp ? endTime - block.timestamp : 0;
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

    function _checkSeller() internal view {
        if (msg.sender != seller) revert OnlySellerCanCall();
    }

    function _checkAuctionNotFinalized() internal view {
        if (finalized) revert AuctionAlreadyFinalized();
    }

    function _checkAuctionEnded() internal view {
        if (block.timestamp < endTime) revert AuctionNotYetEnded();
    }

    function _checkAuctionOngoing() internal view {
        if (block.timestamp >= endTime) revert AuctionEnded();
    }
}
