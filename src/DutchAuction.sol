// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title DutchAuction
 * @notice Implements a standard Dutch auction that starts at a given high price and goes down over time.
 * @dev Extend this to modify the price decay logic, asset transfer, or other mechanics.
 */
contract DutchAuction {
    // -------------------------
    // State Variables
    // -------------------------

    /// @notice The address of the seller
    address public seller;

    /// @notice The auction start time
    uint256 public startTime;

    /// @notice The time in seconds after the start at which the auction fully ends (no price goes below floor)
    uint256 public duration;

    /// @notice The initial starting price at `startTime`
    uint256 public startPrice;

    /// @notice The lowest possible price at the end of the auction
    uint256 public floorPrice;

    /// @notice Indicates if the auction has been successfully purchased
    bool public purchased;

    /// @notice The buyer who successfully purchased the item
    address public buyer;

    // -------------------------
    // Events
    // -------------------------

    event AuctionStarted(
        address indexed seller, uint256 startPrice, uint256 floorPrice, uint256 startTime, uint256 duration
    );

    event Purchased(address indexed buyer, uint256 amount);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    // -------------------------
    // Modifiers
    // -------------------------

    modifier onlySeller() {
        require(msg.sender == seller, "Only seller can call this");
        _;
    }

    modifier auctionActive() {
        require(block.timestamp >= startTime, "Auction not started yet.");
        require(!purchased, "Item already purchased.");
        require(block.timestamp < startTime + duration, "Auction ended without purchase.");
        _;
    }

    // -------------------------
    // Constructor
    // -------------------------

    /**
     * @param _startPrice The price at the beginning of the auction
     * @param _floorPrice The minimum price at the end of the auction
     * @param _startTime The start time of the auction (timestamp in seconds)
     * @param _duration The total duration of the price decrease
     */
    constructor(uint256 _startPrice, uint256 _floorPrice, uint256 _startTime, uint256 _duration) {
        require(_floorPrice <= _startPrice, "Floor price must be <= start price.");
        require(_duration > 0, "Duration must be > 0.");
        require(_startTime >= block.timestamp, "Start time must be in the future or now.");

        seller = msg.sender;
        startPrice = _startPrice;
        floorPrice = _floorPrice;
        startTime = _startTime;
        duration = _duration;

        emit AuctionStarted(seller, startPrice, floorPrice, startTime, duration);
    }

    // -------------------------
    // Public / External Functions
    // -------------------------

    /**
     * @notice Buy the item at the current price.
     * @dev The auction ends immediately upon purchase. Any excess payment is refunded.
     */
    function buy() external payable auctionActive {
        uint256 price = currentPrice();
        require(msg.value >= price, "Not enough funds sent.");

        purchased = true;
        buyer = msg.sender;

        // Refund excess if overpaid
        uint256 excess = msg.value > price ? (msg.value - price) : 0;
        if (excess > 0) {
            payable(msg.sender).transfer(excess);
            emit FundsWithdrawn(msg.sender, excess);
        }

        // Transfer funds to the seller
        payable(seller).transfer(price);
        emit FundsWithdrawn(seller, price);

        emit Purchased(msg.sender, price);

        // Transfer the asset to the buyer (to be implemented by extending the contract)
        _transferAsset(msg.sender);
    }

    /**
     * @notice Returns the current price based on how much time has elapsed.
     */
    function currentPrice() public view returns (uint256) {
        return _currentPrice();
    }

    // -------------------------
    // Extension Points
    // -------------------------

    /**
     * @dev Hook to calculate the current price. You can override this in a child contract
     *      to change the price function. The default is a linear decrease from `startPrice` to `floorPrice`.
     */
    function _currentPrice() internal view virtual returns (uint256) {
        if (block.timestamp <= startTime) {
            return startPrice;
        }

        uint256 elapsed = block.timestamp > startTime ? block.timestamp - startTime : 0;
        if (elapsed >= duration) {
            return floorPrice;
        }

        uint256 priceDecrease = ((startPrice - floorPrice) * elapsed) / duration;
        return startPrice - priceDecrease;
    }

    /**
     * @notice Hook for child contracts to handle asset transfer logic.
     *         For example, transfer an NFT from `seller` to `buyer`.
     */
    function _transferAsset(address to) internal virtual {
        // No-op in base contract
    }
}
