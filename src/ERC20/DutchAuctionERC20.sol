// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../DutchAuction.sol";

/**
 * @title DutchAuctionERC20
 * @notice A Dutch Auction contract that uses an ERC20 token for payment.
 *         For simplicity, all ERC20 tokens are pre-minted to the auction contract.
 *
 *
 * Note: This contract is just an example. When launching a new collection,
 *       you would usually mint the NFTs directly to the buyer instead of holding them in the auction contract.
 */
contract DutchAuctionERC20 is DutchAuction {
    using SafeERC20 for ERC20;

    ERC20 public immutable token;
    

    /// @dev Thrown when trying to use a non-ERC20 token
    error InvalidERC20();

    modifier isERC20() {
        if (address(token) == address(0)) revert InvalidERC20();
        _;
    }

    // -------------------------
    // Constructor
    // -------------------------

    /**
     * @param _token The address of the ERC20 token
     * @param _seller The address of the seller
     * @param _startPrice Price at start time (per item)
     * @param _floorPrice The minimum price at the end (per item)
     * @param _startTime When the auction starts
     * @param _duration How long it lasts
     * @param _inventory How many identical items are for sale
     */
    constructor(
        address _token,
        address _seller,
        uint256 _startPrice,
        uint256 _floorPrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _inventory
    ) DutchAuction(_seller, _startPrice, _floorPrice, _startTime, _duration, _inventory) {
        if (_token == address(0)) revert InvalidERC20();
        token = ERC20(_token);
    }

    /**
     * @notice Buy `quantity` items at the current price using ERC20 tokens.
     * @dev The cost is `quantity * currentPrice()` in ERC20 tokens.
     *      Any ETH sent with this transaction is ignored and returned.
     * @param quantity The number of items to buy
     */
    function buy(uint256 quantity) external payable virtual override auctionActive nonReentrant {
        if (quantity == 0 || quantity > inventory) revert InvalidQuantity(quantity, inventory);

        uint256 pricePerItem = currentPrice();
        uint256 totalCost = pricePerItem * quantity;

        if (token.balanceOf(msg.sender) < totalCost) revert InsufficientAmount(token.balanceOf(msg.sender), totalCost);

        _beforeBuy(msg.sender, quantity, pricePerItem, msg.value);

        inventory -= quantity;

        _transferAssetToBuyer(msg.sender, quantity);
        
        token.safeTransferFrom(msg.sender, address(this), totalCost);

        // Return any ETH sent (should be 0 for normal operation)
        if (msg.value > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: msg.value}("");
            require(refundSuccess, "ETH refund failed");
        }

        _afterBuy(msg.sender, quantity, pricePerItem, totalCost);
        emit Purchased(msg.sender, quantity, totalCost);
    }

    /**
     * @notice Send all token funds in the contract to the seller.
     * @dev Overrides the parent implementation to handle ERC20 tokens instead of ETH.
     */
    function withdrawSellerProceeds() external virtual override {
        uint256 amount = token.balanceOf(address(this));
        
        token.safeTransfer(seller, amount);
        
        emit FundsWithdrawn(seller, amount);
    }

    /**
     * @dev Hook called before processing a buy.
     * @param buyer_ The buyer address
     * @param quantity The number of items the buyer wants
     * @param pricePerItem The current price per item
     * @param amountPaid The total amount sent by the buyer
     */
    function _beforeBuy(address buyer_, uint256 quantity, uint256 pricePerItem, uint256 amountPaid) internal virtual override {
        // No-op by default
    }

    /**
     * @dev Hook called after a successful buy.
     * @param buyer_ The buyer address
     * @param quantity The number of items bought
     * @param pricePerItem The price per item for this purchase
     * @param totalCost The total cost paid by the buyer
     */
    function _afterBuy(address buyer_, uint256 quantity, uint256 pricePerItem, uint256 totalCost) internal virtual override {
        // No-op by default
    }

     /**
     * @dev MUST be implemented to transfer `quantity` items of the asset to `buyer_`.
     *      It is recommended that assets are escrowed in the contract and transferred to the buyer here.
     *      @param buyer_ The buyer's address
     *      @param quantity The quantity of items to transfer
     */
    function _transferAssetToBuyer(address buyer_, uint256 quantity) internal virtual override {
        // No-op by default
    }

    /**
     * @dev MUST be implemented to transfer unsold items back to the seller after the auction ends.
     * @param seller_ The seller's address
     * @param quantity The quantity of unsold items
     */
    function _withdrawUnsoldAssets(address seller_, uint256 quantity) internal virtual override {
        // No-op by default
    }
}
