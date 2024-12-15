// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title DutchAuction
 * @notice A Dutch auction selling multiple identical items.
 * @dev
 * - The price decreases from `startPrice` to `floorPrice` over `duration`.
 * - Buyers can purchase at the current price until inventory = 0 or time runs out.
 * - Once time runs out or inventory hits zero, the auction is considered ended.
 * - If inventory remains after time ends, the seller can reclaim them via `withdrawUnsoldAssets()`.
 */
abstract contract DutchAuction is ReentrancyGuard {
    /// @notice The address of the seller
    address internal immutable seller;

    /// @notice The auction start time
    uint256 internal immutable startTime;

    /// @notice The duration of the auction in seconds
    uint256 internal immutable duration;

    /// @notice The initial start price at `startTime`
    uint256 internal immutable startPrice;

    /// @notice The lowest possible price at the end of `duration`
    uint256 internal immutable floorPrice;

    /// @notice The number of identical items available for sale
    uint256 internal inventory;

    event AuctionStarted(
        address indexed seller,
        uint256 startPrice,
        uint256 floorPrice,
        uint256 startTime,
        uint256 duration,
        uint256 inventory
    );

    event Purchased(address indexed buyer, uint256 quantity, uint256 totalPaid);
    event FundsWithdrawn(address indexed recipient, uint256 amount);
    event UnsoldAssetsWithdrawn(address indexed seller, uint256 quantity);

    error AuctionNotStarted();
    error AuctionEnded();
    error InsufficientAmount(uint256 sent, uint256 required);
    error NoProceedsAvailable();
    error InvalidQuantity(uint256 quantity, uint256 available);
    error AuctionNotEndedForWithdraw();
    error NoUnsoldAssetsToWithdraw();
    error FloorPriceExceedsStartPrice(uint256 floorPrice, uint256 startPrice);
    error ZeroDuration();
    error StartTimeInPast(uint256 startTime, uint256 blockTimestamp);
    error ZeroInventory();

    // -------------------------
    // Modifiers
    // -------------------------

    modifier auctionActive() {
        // Auction is active if startTime < time < end and inventory > 0
        if (block.timestamp < startTime) revert AuctionNotStarted();
        if (isFinished()) revert AuctionEnded();
        _;
    }

    // -------------------------
    // Constructor
    // -------------------------

    /**
     * @param _seller The address of the seller
     * @param _startPrice Price at start time (per item)
     * @param _floorPrice The minimum price at the end (per item)
     * @param _startTime When the auction starts
     * @param _duration How long it lasts
     * @param _inventory How many identical items are for sale
     */
    constructor(
        address _seller,
        uint256 _startPrice,
        uint256 _floorPrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _inventory
    ) {
        if (_floorPrice > _startPrice) revert FloorPriceExceedsStartPrice(_floorPrice, _startPrice);
        if (_duration == 0) revert ZeroDuration();
        if (_startTime < block.timestamp) revert StartTimeInPast(_startTime, block.timestamp);
        if (_inventory == 0) revert ZeroInventory();

        seller = _seller;
        startPrice = _startPrice;
        floorPrice = _floorPrice;
        startTime = _startTime;
        duration = _duration;
        inventory = _inventory;

        emit AuctionStarted(seller, startPrice, floorPrice, startTime, duration, inventory);
    }

    // -------------------------
    // Public / External
    // -------------------------

    /**
     * @notice Buy `quantity` items at the current price.
     * @dev The cost is `quantity * currentPrice()`.
     *      If more ETH than required is sent, excess is refunded.
     * @param quantity The number of items to buy
     */
    function buy(uint256 quantity) external payable auctionActive nonReentrant {
        if (quantity == 0 || quantity > inventory) revert InvalidQuantity(quantity, inventory);

        uint256 pricePerItem = currentPrice();
        uint256 totalCost = pricePerItem * quantity;
        if (msg.value < totalCost) revert InsufficientAmount(msg.value, totalCost);

        _beforeBuy(msg.sender, quantity, pricePerItem, msg.value);

        // Reduce inventory
        inventory -= quantity;

        uint256 excess = msg.value - totalCost;
        if (excess > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: excess}("");
            require(refundSuccess, "Refund failed");
        }

        // Transfer assets to buyer
        _transferAssetToBuyer(msg.sender, quantity);

        _afterBuy(msg.sender, quantity, pricePerItem, totalCost);

        emit Purchased(msg.sender, quantity, totalCost);
    }

    /**
     * @notice Send all funds in the contract to the seller.
     * @dev By default, this will send all funds to the seller.
     *      It is safe to send all funds to the seller, since buyers are refunded immediately if they send excess funds.
     *      Override to implement custom logic if necessary (e.g. sending the funds to a different address or burning them)
     *      When overriding, make sure to add necessary access control.
     */
    function withdrawSellerProceeds() external virtual {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NoProceedsAvailable();

        (bool success,) = payable(seller).call{value: amount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(seller, amount);
    }

    /**
     * @notice Send unsold assets(if any) back to the seller after the auction ends.
     * @dev This can only be done if the auction ended due to time running out and inventory still > 0.
     *      Override to implement custom logic if necessary (e.g. sending the assets to a different address)
     *      When overriding, make sure to add necessary access control.
     */
    function withdrawUnsoldAssets() external virtual {
        if (!isFinished()) revert AuctionNotEndedForWithdraw();

        uint256 remaining = inventory;
        if (remaining == 0) revert NoUnsoldAssetsToWithdraw(); // nothing to withdraw if sold out

        // Set inventory to 0 because we're moving them out of the contract
        inventory = 0;

        // Implementer handles the actual asset transfer to the seller
        _withdrawUnsoldAssets(seller, remaining);

        emit UnsoldAssetsWithdrawn(seller, remaining);
    }

    // -------------------------
    // View Functions
    // -------------------------

    /**
     * @notice Gets the current price per item at the current timestamp.
     * @dev By default, the price is a linear decrease from `startPrice` to `floorPrice` over `duration`.
     *      Override to implement custom curve if necessary.
     * @return The current price per item.
     */
    function currentPrice() public view virtual returns (uint256) {
        if (block.timestamp <= startTime) {
            return startPrice;
        }
        uint256 endTime = getEndTime();
        if (block.timestamp >= endTime) {
            return floorPrice;
        }

        return floorPrice + ((startPrice - floorPrice) * (endTime - block.timestamp)) / duration;
    }

    function getSeller() public view returns (address) {
        return seller;
    }

    function getStartTime() public view returns (uint256) {
        return startTime;
    }

    function getStartPrice() public view returns (uint256) {
        return startPrice;
    }

    function getFloorPrice() public view returns (uint256) {
        return floorPrice;
    }

    function getInventory() public view returns (uint256) {
        return inventory;
    }

    function getEndTime() public view returns (uint256) {
        return startTime + duration;
    }

    function isFinished() public view returns (bool) {
        return block.timestamp >= getEndTime() || inventory == 0;
    }

    // -------------------------
    // Hooks for Extension
    // -------------------------

    /**
     * @dev Hook called before processing a buy.
     * @param buyer_ The buyer address
     * @param quantity The number of items the buyer wants
     * @param pricePerItem The current price per item
     * @param amountPaid The total amount sent by the buyer
     */
    function _beforeBuy(address buyer_, uint256 quantity, uint256 pricePerItem, uint256 amountPaid) internal virtual {
        // No-op by default
    }

    /**
     * @dev Hook called after a successful buy.
     * @param buyer_ The buyer address
     * @param quantity The number of items bought
     * @param pricePerItem The price per item for this purchase
     * @param totalCost The total cost paid by the buyer
     */
    function _afterBuy(address buyer_, uint256 quantity, uint256 pricePerItem, uint256 totalCost) internal virtual {
        // No-op by default
    }

    /**
     * @dev Must be implemented to transfer `quantity` items of the asset to `buyer_`.
     *      It is recommended that assets are escrowed in the contract and transferred to the buyer here.
     *      @param buyer_ The buyer's address
     *      @param quantity The quantity of items to transfer
     */
    function _transferAssetToBuyer(address buyer_, uint256 quantity) internal virtual;

    /**
     * @dev Must be implemented to transfer unsold items back to the seller after the auction ends.
     * @param seller_ The seller's address
     * @param quantity The quantity of unsold items
     */
    function _withdrawUnsoldAssets(address seller_, uint256 quantity) internal virtual;
}
