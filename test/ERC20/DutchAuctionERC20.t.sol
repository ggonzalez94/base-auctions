// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DutchAuctionERC20} from "../../src/ERC20/DutchAuctionERC20.sol";
import {DutchAuction} from "../../src/DutchAuction.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        // Initialize with no tokens
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock implementation of DutchAuctionERC20 for testing
contract MockDutchAuctionERC20 is DutchAuctionERC20 {
    mapping(address => uint256) public buyerItemCount;
    bool public unsoldWithdrawn;

    constructor(
        address _token,
        address _seller,
        uint256 _startPrice,
        uint256 _floorPrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _inventory
    ) DutchAuctionERC20(_token, _seller, _startPrice, _floorPrice, _startTime, _duration, _inventory) {
        // No custom logic needed for now
    }

    // Here you would normally transfer the actual assets to the buyer
    function _transferAssetToBuyer(address buyer_, uint256 quantity) internal override {
        buyerItemCount[buyer_] += quantity;
    }

    // Here you would normally transfer the unsold assets to the seller if there was no winner
    function _withdrawUnsoldAssets(address, /* seller_ */ uint256 /* quantity */ ) internal override {
        unsoldWithdrawn = true;
    }
    
    // Allow test contract to send ETH directly to the contract for testing ETH handling
    receive() external payable {}
}

contract DutchAuctionERC20Test is Test {
    // Test addresses
    address seller = address(0xA1);
    address buyer1 = address(0xB1);
    address buyer2 = address(0xB2);
    address randomUser = address(0xC1);

    // Auction parameters
    uint256 startPrice = 100 ether; // 100 tokens
    uint256 floorPrice = 10 ether;  // 10 tokens
    uint256 startTime = 1000;       // We'll warp to 1000 in setUp
    uint256 duration = 1 days;
    uint256 inventory = 50;         // 50 identical items

    // Token and auction contracts
    MockERC20 paymentToken;
    MockDutchAuctionERC20 auction;

    function setUp() external {
        // Warp to a known start time
        vm.warp(startTime);

        // Deploy the mock ERC20 token
        paymentToken = new MockERC20("Test Token", "TEST");
        
        // Deploy the mock Dutch Auction with ERC20
        auction = new MockDutchAuctionERC20(
            address(paymentToken),
            seller,
            startPrice,
            floorPrice,
            startTime,
            duration,
            inventory
        );

        // Mint tokens to test addresses
        paymentToken.mint(buyer1, 10000 ether); // Increased from 1000 to 10000
        paymentToken.mint(buyer2, 10000 ether); // Increased from 1000 to 10000
        paymentToken.mint(randomUser, 100 ether);

        // Approve auction contract to spend tokens
        vm.startPrank(buyer1);
        paymentToken.approve(address(auction), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(buyer2);
        paymentToken.approve(address(auction), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(randomUser);
        paymentToken.approve(address(auction), type(uint256).max);
        vm.stopPrank();
    }

    // -----------------------------------
    // Initialization & Constructor Tests
    // -----------------------------------

    function test_constructorInitializesStateCorrectly() external view {
        assertEq(auction.getSeller(), seller, "Seller should match constructor arg");
        assertEq(auction.getStartTime(), startTime, "startTime mismatch");
        assertEq(auction.getStartPrice(), startPrice, "startPrice mismatch");
        assertEq(auction.getFloorPrice(), floorPrice, "floorPrice mismatch");
        assertEq(auction.getInventory(), inventory, "inventory mismatch");
        assertEq(address(auction.token()), address(paymentToken), "token address mismatch");
        assertFalse(auction.isFinished(), "Auction should not be finished initially");
    }

    function test_constructorEmitsAuctionCreatedEvent() external {
        vm.expectEmit();
        emit DutchAuction.AuctionCreated(seller, startPrice, floorPrice, startTime, duration, inventory);
        new MockDutchAuctionERC20(
            address(paymentToken),
            seller,
            startPrice,
            floorPrice,
            startTime,
            duration,
            inventory
        );
    }

    function test_constructor_RevertWhen_ZeroDuration() external {
        vm.expectRevert(DutchAuction.InvalidDuration.selector);
        new MockDutchAuctionERC20(
            address(paymentToken),
            seller,
            startPrice,
            floorPrice,
            startTime + 10,
            0, // zero duration
            10
        );
    }

    function test_constructor_RevertWhen_StartTimeInPast() external {
        // block.timestamp = 1000 in setUp, so _startTime < block.timestamp fails
        vm.expectRevert(
            abi.encodeWithSelector(
                DutchAuction.StartTimeInPast.selector,
                900, // startTime
                1000 // blockTimestamp
            )
        );
        new MockDutchAuctionERC20(
            address(paymentToken),
            seller,
            startPrice,
            floorPrice,
            900,
            1 days,
            10
        );
    }

    function test_constructor_RevertWhen_ZeroInventory() external {
        vm.expectRevert(DutchAuction.InvalidInventory.selector);
        new MockDutchAuctionERC20(
            address(paymentToken),
            seller,
            startPrice,
            floorPrice,
            startTime + 10,
            1 days,
            0 // zero inventory
        );
    }

    function test_constructor_RevertWhen_InvalidERC20() external {
        vm.expectRevert(DutchAuctionERC20.InvalidERC20.selector);
        new MockDutchAuctionERC20(
            address(0), // zero address for token
            seller,
            startPrice,
            floorPrice,
            startTime + 10,
            1 days,
            10
        );
    }

    // -----------------------------------
    // Price Function Tests
    // -----------------------------------

    function test_currentPriceDecreasesOverTime() external {
        // Initially (block.timestamp == startTime), price = startPrice
        uint256 p0 = auction.currentPrice();
        assertEq(p0, startPrice, "price at startTime should be startPrice");

        // Warp half the duration => price should be halfway between startPrice and floorPrice
        vm.warp(startTime + (duration / 2));
        uint256 pHalf = auction.currentPrice();
        uint256 expectedHalf = floorPrice + ((startPrice - floorPrice) / 2);
        assertEq(pHalf, expectedHalf, "price at half-time mismatch");

        // Warp to end => price = floorPrice
        vm.warp(startTime + duration + 1);
        uint256 pEnd = auction.currentPrice();
        assertEq(pEnd, floorPrice, "price after endTime should be floorPrice");
    }

    // -----------------------------------
    // Buying Tests
    // -----------------------------------

    function test_buyPurchasesItems() external {
        // buyer1 buys 5 items at the start price
        uint256 quantity = 5;
        uint256 costAtStart = quantity * startPrice; // 5 * 100 tokens = 500 tokens

        vm.startPrank(buyer1);
        vm.expectEmit();
        emit DutchAuction.Purchased(buyer1, quantity, costAtStart);
        auction.buy(quantity);
        vm.stopPrank();

        // Check inventory
        uint256 invAfter = auction.getInventory();
        assertEq(invAfter, inventory - quantity, "inventory not decreased by quantity");

        // buyer1 should have 5 items
        assertEq(auction.buyerItemCount(buyer1), 5, "buyer1 item count mismatch");
        
        // Check token balances
        assertEq(paymentToken.balanceOf(buyer1), 10000 ether - costAtStart, "buyer1 token balance incorrect");
        assertEq(paymentToken.balanceOf(address(auction)), costAtStart, "auction token balance incorrect");
    }

    function test_buy_ReturnsNativeTokens() external {
        uint256 quantity = 5;
        
        vm.startPrank(buyer1);
        // Give buyer some ETH
        vm.deal(buyer1, 2 ether);
        uint256 ethBefore = buyer1.balance;
        
        // Try to send ETH with the transaction, which should be returned
        auction.buy{value: 1 ether}(quantity);
        
        // Check that the buyer's ETH balance is unchanged (ETH was returned)
        assertEq(buyer1.balance, ethBefore - 1 ether + 1 ether, "buyer ETH should be returned");
        
        // Check that the contract balance is still 0 ETH
        assertEq(address(auction).balance, 0, "auction should not keep any ETH");
        vm.stopPrank();
    }

    function test_buy_TransactWithEthStillUsesTokens() external {
        uint256 quantity = 5;
        uint256 costAtStart = quantity * startPrice; // 5 * 100 tokens = 500 tokens
        
        // Give buyer1 some ETH
        vm.deal(buyer1, 10 ether);
        
        // Initial balances
        uint256 buyerEthBefore = buyer1.balance;
        uint256 buyerTokensBefore = paymentToken.balanceOf(buyer1);
        
        vm.startPrank(buyer1);
        // Send ETH with the transaction - it should be returned
        auction.buy{value: 5 ether}(quantity);
        vm.stopPrank();
        
        // Check balances after purchase
        assertEq(buyer1.balance, buyerEthBefore, "ETH should be returned to buyer");
        assertEq(paymentToken.balanceOf(buyer1), buyerTokensBefore - costAtStart, "Tokens should be deducted from buyer");
        assertEq(paymentToken.balanceOf(address(auction)), costAtStart, "Auction should receive tokens");
        assertEq(address(auction).balance, 0, "Auction should not keep any ETH");
        
        // Verify the purchase was successful using tokens, not ETH
        assertEq(auction.getInventory(), inventory - quantity, "Inventory should be reduced");
        assertEq(auction.buyerItemCount(buyer1), quantity, "Buyer should receive items");
    }

    function test_buy_RevertWhenInsufficientTokensEvenWithETH() external {
        // Create a new user with no tokens but plenty of ETH
        address poorUser = address(0xD1);
        vm.deal(poorUser, 1000 ether); // Give them lots of ETH
        
        // Approve the auction to spend tokens (even though they have none)
        vm.startPrank(poorUser);
        paymentToken.approve(address(auction), type(uint256).max);
        
        // Try to buy with ETH but no tokens - should revert
        vm.expectRevert(abi.encodeWithSelector(
            DutchAuction.InsufficientAmount.selector, 
            0, // token balance
            100 ether // required (1 item at startPrice)
        ));
        auction.buy{value: 200 ether}(1); // Send double the required ETH
        vm.stopPrank();
        
        // Verify no purchase occurred
        assertEq(auction.getInventory(), inventory, "Inventory should remain unchanged");
        assertEq(auction.buyerItemCount(poorUser), 0, "User should not receive any items");
        assertEq(paymentToken.balanceOf(address(auction)), 0, "Auction should not receive any tokens");
    }

    function test_buyAtLastSecondSucceeds() external {
        vm.warp(startTime + duration);
        vm.startPrank(buyer1);

        vm.expectEmit();
        emit DutchAuction.Purchased(buyer1, 1, auction.currentPrice());
        auction.buy(1);
        vm.stopPrank();
    }

    function test_buy_RevertWhen_AuctionNotStarted() external {
        // Deploy a new auction that starts in the future
        MockDutchAuctionERC20 futureAuction = new MockDutchAuctionERC20(
            address(paymentToken),
            seller,
            startPrice,
            floorPrice,
            startTime + 1000, // starts 1000 sec in the future
            duration,
            inventory
        );

        vm.startPrank(buyer1);
        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        futureAuction.buy(1);
        vm.stopPrank();
    }

    function test_buy_RevertWhen_AuctionEnded() external {
        // warp after end
        vm.warp(startTime + duration + 1);

        vm.startPrank(buyer1);
        vm.expectRevert(DutchAuction.AuctionEnded.selector);
        auction.buy(1);
        vm.stopPrank();
    }

    function test_buy_RevertWhen_InvalidQuantity() external {
        // Zero quantity
        vm.prank(buyer1);
        vm.expectRevert(abi.encodeWithSelector(DutchAuction.InvalidQuantity.selector, 0, inventory));
        auction.buy(0);

        // Exceed inventory
        vm.prank(buyer2);
        vm.expectRevert(abi.encodeWithSelector(DutchAuction.InvalidQuantity.selector, inventory + 1, inventory));
        auction.buy(inventory + 1);
    }

    function test_buy_RevertWhen_InsufficientTokens() external {
        // randomUser only has 100 tokens, but needs 200 tokens to buy 2 items at startPrice
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(
            DutchAuction.InsufficientAmount.selector, 
            100 ether, // balance
            200 ether  // required
        ));
        auction.buy(2);
    }

    // -----------------------------------
    // Seller Proceeds Tests
    // -----------------------------------

    function test_withdrawSellerProceeds() external {
        // Make initial purchases to get tokens into the contract
        uint256 testStartPrice = auction.currentPrice();
        
        // Check that the contract has no tokens initially
        assertEq(paymentToken.balanceOf(address(auction)), 0, "auction should have no tokens initially");
        
        // First purchase: buyer1 buys 2 items
        vm.prank(buyer1);
        auction.buy(2);
        
        // Second purchase: buyer2 buys 1 item after half duration
        vm.warp(startTime + (duration / 2));
        uint256 halfDurationPrice = auction.currentPrice();
        vm.prank(buyer2);
        auction.buy(1);
        
        // Calculate expected tokens in contract
        uint256 expectedTokens = (2 * testStartPrice) + halfDurationPrice;
        
        // Verify contract has tokens and seller has none
        assertEq(paymentToken.balanceOf(address(auction)), expectedTokens, "auction should have collected tokens");
        assertEq(paymentToken.balanceOf(seller), 0, "seller should have no tokens initially");
        
        // Check exact token amounts for debugging
        console.log("Contract token balance:", paymentToken.balanceOf(address(auction)));
        console.log("Expected tokens:", expectedTokens);
        
        // Withdraw tokens to seller
        vm.expectEmit();
        emit DutchAuction.FundsWithdrawn(seller, expectedTokens);
        auction.withdrawSellerProceeds();
        
        // Verify balances after withdrawal
        assertEq(paymentToken.balanceOf(address(auction)), 0, "auction should have no tokens after withdrawal");
        assertEq(paymentToken.balanceOf(seller), expectedTokens, "seller should receive all tokens");
    }

    function test_withdrawSellerProceeds_OnlyTransfersERC20() external {
        // buyer1 buys 2 items at start price
        uint256 testStartPrice = auction.currentPrice();
        vm.prank(buyer1);
        auction.buy(2);
        
        // Send some ETH to the contract directly
        (bool success, ) = payable(address(auction)).call{value: 5 ether}("");
        require(success, "Failed to send ETH to contract");
        
        // Verify contract has both tokens and ETH
        uint256 contractTokenBalance = paymentToken.balanceOf(address(auction));
        assertEq(contractTokenBalance, testStartPrice * 2, "auction token balance incorrect");
        assertEq(address(auction).balance, 5 ether, "auction ETH balance incorrect");
        
        // Withdraw proceeds - should only transfer tokens, not ETH
        auction.withdrawSellerProceeds();
        
        // Check balances after withdrawal
        assertEq(paymentToken.balanceOf(seller), testStartPrice * 2, "seller should receive tokens");
        assertEq(paymentToken.balanceOf(address(auction)), 0, "auction should have no tokens after withdrawal");
        assertEq(address(auction).balance, 5 ether, "auction ETH balance should remain unchanged");
        assertEq(seller.balance, 0, "seller should not receive any ETH");
    }

    function test_withdrawSellerProceeds_TransfersCorrectTokenAmount() external {
        // Have multiple buyers purchase at different price points
        
        // First purchase at start price
        vm.prank(buyer1);
        auction.buy(5); // 5 items at startPrice (100 tokens each)
        
        // Second purchase at mid-auction (price has decreased)
        vm.warp(startTime + (duration / 2));
        uint256 midPrice = auction.currentPrice(); // Should be ~55 tokens
        vm.prank(buyer2);
        auction.buy(3); // 3 items at midPrice
        
        // Third purchase near the end (price close to floor)
        vm.warp(startTime + (duration * 9 / 10)); // 90% through auction
        uint256 latePrice = auction.currentPrice(); // Should be ~19 tokens
        vm.prank(buyer1);
        auction.buy(2); // 2 items at latePrice
        
        // Calculate expected total proceeds
        uint256 expectedTotal = (5 * startPrice) + (3 * midPrice) + (2 * latePrice);
        
        // Verify contract has the correct token balance
        assertEq(paymentToken.balanceOf(address(auction)), expectedTotal, "auction should have collected the correct amount");
        
        // Withdraw proceeds
        auction.withdrawSellerProceeds();
        
        // Verify seller received the exact amount
        assertEq(paymentToken.balanceOf(seller), expectedTotal, "seller should receive the exact token amount");
        assertEq(paymentToken.balanceOf(address(auction)), 0, "auction should have 0 tokens after withdrawal");
    }

    // -----------------------------------
    // Auction End & Unsold Withdrawal
    // -----------------------------------

    function test_isFinishedByTime() external {
        // initially not finished
        assertFalse(auction.isFinished(), "should not be finished yet");

        // warp after end
        vm.warp(startTime + duration + 1);
        assertTrue(auction.isFinished(), "should be finished after time expires");
    }

    function test_isFinishedByInventory() external {
        // Make sure buyer1 has enough tokens
        paymentToken.mint(buyer1, 10000 ether); // Add more tokens to cover the full inventory
        
        // buyer1 purchases entire inventory
        vm.prank(buyer1);
        auction.buy(inventory);
        
        // now inventory=0 => isFinished should be true
        assertTrue(auction.isFinished(), "auction should be finished if inventory=0");
    }

    function test_withdrawUnsoldAssets() external {
        // Make sure buyer1 has enough tokens
        paymentToken.mint(buyer1, 10000 ether);
        
        // Let half of inventory (25) be sold
        vm.prank(buyer1);
        auction.buy(25);

        // warp to end => time is up
        vm.warp(startTime + duration + 1);

        // seller withdraws 25 unsold items
        vm.prank(seller);
        vm.expectEmit();
        emit DutchAuction.UnsoldAssetsWithdrawn(seller, 25);
        auction.withdrawUnsoldAssets();

        // mock sets inventory to 0 & unsoldWithdrawn = true
        assertEq(auction.getInventory(), 0, "inventory should be 0 after withdraw");
        assertTrue(auction.unsoldWithdrawn(), "unsoldWithdrawn should be true");
    }

    function test_withdrawUnsoldAssets_RevertWhen_AuctionNotEnded() external {
        // warp to half time and buy 1 item
        vm.warp(startTime + (duration / 2));
        vm.prank(buyer1);
        auction.buy(1);

        vm.expectRevert(DutchAuction.AuctionNotEnded.selector);
        auction.withdrawUnsoldAssets();
    }

    function test_withdrawUnsoldAssets_RevertWhen_NoUnsoldAssets() external {
        // Make sure buyer1 has enough tokens
        paymentToken.mint(buyer1, 10000 ether);
        
        // buyer1 buys entire inventory
        vm.prank(buyer1);
        auction.buy(inventory);

        // now inventory=0 => revert
        vm.expectRevert(DutchAuction.NoUnsoldAssetsToWithdraw.selector);
        auction.withdrawUnsoldAssets();
    }
}
