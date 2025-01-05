// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import {EnglishAuction} from "../src/EnglishAuction.sol";
import "forge-std/Test.sol";

////////////////////////////////////////////////////////////
// Mock Implementations
////////////////////////////////////////////////////////////

contract MockEnglishAuction is EnglishAuction {
    address public winnerAssetRecipient;
    bool public returnAssetToSeller;

    constructor(
        address _seller,
        uint256 _reservePrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _extensionThreshold,
        uint256 _extensionPeriod,
        address _erc20Token
    )
        EnglishAuction(
            _seller,
            _reservePrice,
            _startTime,
            _duration,
            _extensionThreshold,
            _extensionPeriod,
            _erc20Token
        )
    {}

    // Here you would normally transfer the actual asset to the winner(e.g. the NFT)
    // For testing purposes, we just set the winnerAssetRecipient to the winner
    function _transferAssetToWinner(address winner) internal override {
        winnerAssetRecipient = winner;
    }

    // Here you would normally transfer the asset to the seller(e.g. the NFT) if there was no winner
    // For testing purposes, we just set the a boolean flag
    function _transferAssetToSeller() internal override {
        returnAssetToSeller = true;
    }
}

// Mock to test increment requirements
contract MockEnglishAuctionWithIncrement is MockEnglishAuction {
    uint256 public incrementRatio; // e.g. at least 10% higher than current bid

    constructor(
        address _seller,
        uint256 _reservePrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _extensionThreshold,
        uint256 _extensionPeriod,
        address _erc20Token,
        uint256 _incrementRatio
    )
        MockEnglishAuction(
            _seller,
            _reservePrice,
            _startTime,
            _duration,
            _extensionThreshold,
            _extensionPeriod,
            _erc20Token
        )
    {
        incrementRatio = _incrementRatio; // 10 means 10% increments required
    }

    function _validateBidIncrement(uint256 newBid) internal view override {
        uint256 currentHighest = getHighestBid();
        if (newBid <= currentHighest) {
            revert BidNotHighEnough(newBid, currentHighest);
        }
        uint256 requiredIncrement = (currentHighest * incrementRatio) / 100;
        if (newBid < currentHighest + requiredIncrement) {
            revert BidNotHighEnough(newBid, currentHighest + requiredIncrement);
        }
    }
}

////////////////////////////////////////////////////////////
// Test Contract
////////////////////////////////////////////////////////////

contract EnglishAuctionTest is Test {
    address seller = address(0xA1);
    address bidder1 = address(0xB1);
    address bidder2 = address(0xB2);
    address randomUser = address(0xC1);

    uint256 reservePrice = 1 ether;
    uint256 duration = 1 days;
    uint256 startTime = 1000;
    uint256 extensionThreshold = 300; // 5 minutes
    uint256 extensionPeriod = 600; // 10 minutes

    address erc20Token = address(0x0); //To use native currency we can set this to 0x0

    MockEnglishAuction auction;

    function setUp() external {
        // Warp to a known start time for consistent testing
        vm.warp(startTime);
        auction = new MockEnglishAuction(
            seller,
            reservePrice,
            startTime,
            duration,
            extensionThreshold,
            extensionPeriod,
            erc20Token
        );

        vm.deal(bidder1, 10 ether);
        vm.deal(bidder2, 10 ether);
        vm.deal(randomUser, 1 ether);
    }

    //////////////////////////
    // Initialization Tests //
    //////////////////////////

    function test_setUpState() external {
        assertEq(
            auction.getHighestBid(),
            reservePrice,
            "Initial highest bid should match reserve price"
        );
        uint256 expectedEndTime = block.timestamp + duration;
        assertEq(
            auction.getEndTime(),
            expectedEndTime,
            "End time should be start + duration"
        );
        assertEq(
            auction.getHighestBidder(),
            address(0),
            "No highest bidder initially"
        );
        assertEq(
            auction.isFinalized(),
            false,
            "Auction should not be finalized initially"
        );
    }

    //////////////////////////
    // Bidding Tests        //
    //////////////////////////

    function test_placeBid_RevertWhen_BiddingInNativeCurrency() external {
        vm.expectRevert(EnglishAuction.OnlyNativeCurrencyBidsAllowed.selector);
        auction.placeErc20Bid(1 ether);
    }

    function test_placeBid_RevertWhen_StartTimeInTheFuture() external {
        MockEnglishAuction notStartedAuction = new MockEnglishAuction(
            seller,
            reservePrice,
            block.timestamp + 1,
            duration,
            extensionThreshold,
            extensionPeriod,
            erc20Token
        );
        vm.expectRevert(EnglishAuction.AuctionNotStarted.selector);
        notStartedAuction.placeBid{value: 1 ether}();
    }

    function test_placeBidUpdatesHighestBid() external {
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();
        vm.stopPrank();

        assertEq(auction.getHighestBid(), 2 ether, "Highest bid should update");
        assertEq(
            auction.getHighestBidder(),
            bidder1,
            "Highest bidder should update"
        );
    }

    function test_placeBid_RevertWhen_BidBelowOrEqualReservePrice() external {
        vm.startPrank(bidder1);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.BidNotHighEnough.selector,
                1 ether,
                1 ether
            )
        );
        auction.placeBid{value: 1 ether}();
        vm.stopPrank();
    }

    function test_placeBid_RevertWhen_BidNotHigherThanCurrent() external {
        // First valid bid
        vm.prank(bidder1);
        auction.placeBid{value: 3 ether}();

        // Second bid tries equal or lower
        vm.prank(bidder2);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.BidNotHighEnough.selector,
                2 ether,
                3 ether
            )
        );
        auction.placeBid{value: 2 ether}();
    }

    function test_placeBid_RevertWhen_AuctionEnded() external {
        vm.warp(startTime + duration + 1);
        vm.prank(bidder1);
        vm.expectRevert(EnglishAuction.AuctionEnded.selector);
        auction.placeBid{value: 2 ether}();
    }

    //////////////////////////
    // Refund & Withdrawal  //
    //////////////////////////

    function test_withdrawRefund_Works() external {
        // bidder1 makes first bid
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();
        vm.stopPrank();

        // bidder2 outbids bidder1
        vm.startPrank(bidder2);
        auction.placeBid{value: 3 ether}();
        vm.stopPrank();

        // bidder1 should have a refund available
        uint256 bidder1BalanceBefore = bidder1.balance;
        vm.startPrank(bidder1);
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = bidder1.balance;

        assertEq(
            bidder1BalanceAfter,
            bidder1BalanceBefore + 2 ether,
            "Bidder1 should be refunded"
        );
    }

    function test_withdrawRefund_OnlyIncludesLosingBids() external {
        vm.prank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.prank(bidder2);
        auction.placeBid{value: 3 ether}();

        vm.startPrank(bidder1);
        auction.placeBid{value: 4 ether}();

        // bidder1 should only get refunded for their losing bid
        // not for the second bid(which is the highest bid currently)
        // A future optimization could allow existing bidders to use funds they already hold in the contract for future
        // bids
        uint256 bidder1BalanceBefore = bidder1.balance;
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = bidder1.balance;

        assertEq(
            bidder1BalanceAfter,
            bidder1BalanceBefore + 2 ether,
            "Bidder1 should be refunded with only their losing bid"
        );
    }

    function test_withdrawRefund_TransfersZeroToCurrentHighestBidder()
        external
    {
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();

        uint256 bidder1BalanceBefore = bidder1.balance;
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = bidder1.balance;

        assertEq(
            bidder1BalanceAfter,
            bidder1BalanceBefore,
            "Bidder1 should be refunded with zero"
        );
    }

    function test_withdrawSellerProceeds_Works() external {
        vm.startPrank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.startPrank(seller);
        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        uint256 sellerBalanceBefore = seller.balance;
        auction.withdrawSellerProceeds();
        uint256 sellerBalanceAfter = seller.balance;

        assertEq(
            sellerBalanceAfter,
            sellerBalanceBefore + 2 ether,
            "Seller should receive funds"
        );
    }

    function test_withdrawSellerProceeds_TransfersZeroWhenNoProceeds()
        external
    {
        vm.startPrank(seller);
        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        uint256 sellerBalanceBefore = seller.balance;
        auction.withdrawSellerProceeds();
        uint256 sellerBalanceAfter = seller.balance;

        assertEq(
            sellerBalanceAfter,
            sellerBalanceBefore,
            "Seller should receive zero"
        );
    }

    // //////////////////////////
    // // Finalize Auction //
    // //////////////////////////

    function test_finalizeAuction_TransfersAssetToWinner() external {
        vm.prank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        assertEq(
            auction.winnerAssetRecipient(),
            bidder1,
            "Asset should be transferred to bidder1"
        );
    }

    function test_finalizeAuction_RevertWhen_AuctionNotYetEnded() external {
        vm.prank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.expectRevert(EnglishAuction.AuctionNotYetEnded.selector);
        auction.finalizeAuction();
    }

    function test_finalizeAuctionWorksWithNoBids() external {
        // No one bids, just end the auction
        vm.warp(block.timestamp + duration + 1);

        // finalize
        auction.finalizeAuction();

        bool isFinalized = auction.isFinalized();
        assertEq(isFinalized, true, "Auction should be finalized");
        // No winner
        assertEq(
            auction.winnerAssetRecipient(),
            address(0),
            "No winner if no bids"
        );
    }

    function test_finalizeAuction_RevertWhen_AlreadyFinalized() external {
        vm.prank(bidder1);
        auction.placeBid{value: 2 ether}();

        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        vm.expectRevert(EnglishAuction.AuctionAlreadyFinalized.selector);
        auction.finalizeAuction();
    }

    // //////////////////////////
    // // Anti-Sniping Tests   //
    // //////////////////////////

    function test_placeBidExtendsAuctionNearEnd() external {
        // Move close to the end
        uint256 endTimeBefore = auction.getEndTime();
        vm.warp(endTimeBefore - (extensionThreshold - 1));

        // Place a bid to trigger extension
        vm.prank(bidder1);
        auction.placeBid{value: 2 ether}();

        uint256 endTimeAfter = auction.getEndTime();
        assertEq(
            endTimeAfter,
            endTimeBefore + extensionPeriod,
            "Should extend the auction end time"
        );
    }

    function test_placeBidDoesNotExtendWhenNotWithinThreshold() external {
        // Warp at the threshold(should not extend)
        uint256 endTimeBefore = auction.getEndTime();
        vm.warp(endTimeBefore - extensionThreshold);

        // Place a bid
        vm.prank(bidder1);
        auction.placeBid{value: 2 ether}();

        // Should not extend
        uint256 endTimeAfter = auction.getEndTime();
        assertEq(endTimeAfter, endTimeBefore, "No extension should occur");
    }

    function test_placeBidDoesNotExtendWhenThresholdIsZero() external {
        // Deploy a new auction with zero threshold
        MockEnglishAuction noExtendAuction = new MockEnglishAuction(
            seller,
            reservePrice,
            startTime,
            duration,
            0,
            extensionPeriod,
            erc20Token
        );
        uint256 endTimeBefore = noExtendAuction.getEndTime();

        // Warp close to end
        vm.warp(endTimeBefore - 1);

        vm.prank(bidder1);
        noExtendAuction.placeBid{value: 2 ether}();

        // Check no extension
        uint256 endTimeAfter = noExtendAuction.getEndTime();
        assertEq(
            endTimeAfter,
            endTimeBefore,
            "No extension if threshold is zero"
        );
    }

    function test_placeBidDoesNotExtendWhenExtensionPeriodIsZero() external {
        // Deploy a new auction with zero extension period
        MockEnglishAuction noExtendAuction = new MockEnglishAuction(
            seller,
            reservePrice,
            startTime,
            duration,
            extensionThreshold,
            0,
            erc20Token
        );
        uint256 endTimeBefore = noExtendAuction.getEndTime();

        // Warp close to end
        vm.warp(endTimeBefore - 1);

        vm.prank(bidder1);
        noExtendAuction.placeBid{value: 2 ether}();

        // Check no extension
        uint256 endTimeAfter = noExtendAuction.getEndTime();
        assertEq(
            endTimeAfter,
            endTimeBefore,
            "No extension if extension period is zero"
        );
    }

    // //////////////////////////
    // // Increment Tests      //
    // //////////////////////////

    function test_placeBidWithIncrement_RevertWhen_BidNotHighEnough() external {
        // Deploy auction with 10 % increment requirement
        MockEnglishAuctionWithIncrement incrementAuction = new MockEnglishAuctionWithIncrement(
                seller,
                reservePrice,
                startTime,
                duration,
                extensionThreshold,
                extensionPeriod,
                erc20Token,
                10 // 10% increment
            );

        vm.prank(bidder1);
        incrementAuction.placeBid{value: 2 ether}();

        // Bidder2 tries to outbid with only 2.1 ether (less than 10% increment over 2 ether)
        // 10% of 2 ether is 0.2 ether, so must be at least 2.2 ether
        vm.prank(bidder2);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.BidNotHighEnough.selector,
                2.1 ether,
                2.2 ether
            )
        );
        incrementAuction.placeBid{value: 2.1 ether}();
    }

    function test_placeBidWithIncrement_Works() external {
        // Deploy auction with 10 % increment requirement
        MockEnglishAuctionWithIncrement incrementAuction = new MockEnglishAuctionWithIncrement(
                seller,
                reservePrice,
                startTime,
                duration,
                extensionThreshold,
                extensionPeriod,
                erc20Token,
                10 // 10% increment
            );

        vm.prank(bidder1);
        incrementAuction.placeBid{value: 2 ether}();

        // Bidder2 places a valid bid (2.5 ether meets 10% increment)
        vm.prank(bidder2);
        incrementAuction.placeBid{value: 2.5 ether}();

        assertEq(
            incrementAuction.getHighestBidder(),
            bidder2,
            "Bidder2 should now be highest bidder"
        );
        assertEq(
            incrementAuction.getHighestBid(),
            2.5 ether,
            "Highest bid should be updated"
        );
    }
}

contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

contract Erc20EnglishAuctionTest is Test {
    address seller = address(0xA1);
    address bidder1 = address(0xB1);
    address bidder2 = address(0xB2);
    address randomUser = address(0xC1);

    uint256 reservePrice = 1 ether;
    uint256 duration = 1 days;
    uint256 startTime = 1000;
    uint256 extensionThreshold = 300; // 5 minutes
    uint256 extensionPeriod = 600; // 10 minutes

    IERC20 erc20Token; //To use native currency we can set this to 0x0

    MockEnglishAuction auction;

    function setUp() external {
        MockERC20 mockERC20 = new MockERC20("Test Token", "TT", 21 ether);

        // Warp to a known start time for consistent testing
        vm.warp(startTime);
        auction = new MockEnglishAuction(
            seller,
            reservePrice,
            startTime,
            duration,
            extensionThreshold,
            extensionPeriod,
            address(mockERC20)
        );

        erc20Token = IERC20(address(mockERC20));

        deal(address(mockERC20), bidder1, 10 ether);
        deal(address(mockERC20), bidder2, 10 ether);
        deal(address(mockERC20), randomUser, 1 ether);
    }

    function test_setUpState() external {
        assertEq(
            auction.getHighestBid(),
            reservePrice,
            "Initial highest bid should match reserve price"
        );
        uint256 expectedEndTime = block.timestamp + duration;
        assertEq(
            auction.getEndTime(),
            expectedEndTime,
            "End time should be start + duration"
        );
        assertEq(
            auction.getHighestBidder(),
            address(0),
            "No highest bidder initially"
        );
        assertEq(
            auction.isFinalized(),
            false,
            "Auction should not be finalized initially"
        );
    }

    //////////////////////////
    // Bidding Tests        //
    //////////////////////////

    function test_placeBid_RevertWhen_BiddingInNativeCurrency() external {
        vm.expectRevert(EnglishAuction.OnlyErc20BidsAllowed.selector);
        auction.placeBid{value: 1 ether}();
    }

    function test_placeBid_RevertWhen_StartTimeInTheFuture() external {
        MockEnglishAuction notStartedAuction = new MockEnglishAuction(
            seller,
            reservePrice,
            block.timestamp + 1,
            duration,
            extensionThreshold,
            extensionPeriod,
            address(erc20Token)
        );
        vm.expectRevert(EnglishAuction.AuctionNotStarted.selector);
        notStartedAuction.placeBid{value: 1 ether}();
    }

    function test_placeBidUpdatesHighestBid() external {
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);
        vm.stopPrank();

        assertEq(auction.getHighestBid(), 2 ether, "Highest bid should update");
        assertEq(
            auction.getHighestBidder(),
            bidder1,
            "Highest bidder should update"
        );
    }

    function test_placeBid_RevertWhen_BidBelowOrEqualReservePrice() external {
        vm.prank(bidder1);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.BidNotHighEnough.selector,
                1 ether,
                1 ether
            )
        );
        auction.placeErc20Bid(1 ether);
        vm.stopPrank();
    }

    function test_placeBid_RevertWhen_BidNotHigherThanCurrent() external {
        // First valid bid
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 3 ether);
        auction.placeErc20Bid(3 ether);
        vm.stopPrank();

        // Second bid tries equal or lower
        vm.prank(bidder2);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.BidNotHighEnough.selector,
                2 ether,
                3 ether
            )
        );
        auction.placeErc20Bid(2 ether);
    }

    function test_placeBid_RevertWhen_AuctionEnded() external {
        vm.warp(startTime + duration + 1);
        vm.prank(bidder1);
        vm.expectRevert(EnglishAuction.AuctionEnded.selector);
        auction.placeErc20Bid(2 ether);
    }

    //////////////////////////
    // Refund & Withdrawal  //
    //////////////////////////

    function test_withdrawRefund_Works() external {
        // bidder1 makes first bid
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);
        vm.stopPrank();

        // bidder2 outbids bidder1
        vm.startPrank(bidder2);
        erc20Token.approve(address(auction), 3 ether);
        auction.placeErc20Bid(3 ether);
        vm.stopPrank();

        // bidder1 should have a refund available
        uint256 bidder1BalanceBefore = erc20Token.balanceOf(bidder1);
        vm.startPrank(bidder1);
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = erc20Token.balanceOf(bidder1);

        assertEq(
            bidder1BalanceAfter,
            bidder1BalanceBefore + 2 ether,
            "Bidder1 should be refunded"
        );
    }

    function test_withdrawRefund_OnlyIncludesLosingBids() external {
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);
        vm.stopPrank();

        vm.startPrank(bidder2);
        erc20Token.approve(address(auction), 3 ether);
        auction.placeErc20Bid(3 ether);
        vm.stopPrank();

        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 4 ether);
        auction.placeErc20Bid(4 ether);

        // bidder1 should only get refunded for their losing bid
        // not for the second bid(which is the highest bid currently)
        // A future optimization could allow existing bidders to use funds they already hold in the contract for future
        // bids
        uint256 bidder1BalanceBefore = erc20Token.balanceOf(bidder1);
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = erc20Token.balanceOf(bidder1);

        assertEq(
            bidder1BalanceAfter,
            bidder1BalanceBefore + 2 ether,
            "Bidder1 should be refunded with only their losing bid"
        );
    }

    function test_withdrawRefund_TransfersZeroToCurrentHighestBidder()
        external
    {
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);

        uint256 bidder1BalanceBefore = erc20Token.balanceOf(bidder1);
        auction.withdrawRefund();
        uint256 bidder1BalanceAfter = erc20Token.balanceOf(bidder1);

        assertEq(
            bidder1BalanceAfter,
            bidder1BalanceBefore,
            "Bidder1 should be refunded with zero"
        );
    }

    function test_withdrawSellerProceeds_Works() external {
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);

        vm.startPrank(seller);
        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        uint256 sellerBalanceBefore = erc20Token.balanceOf(seller);
        auction.withdrawSellerProceeds();
        uint256 sellerBalanceAfter = erc20Token.balanceOf(seller);

        assertEq(
            sellerBalanceAfter,
            sellerBalanceBefore + 2 ether,
            "Seller should receive funds"
        );
    }

    function test_withdrawSellerProceeds_TransfersZeroWhenNoProceeds()
        external
    {
        vm.startPrank(seller);
        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        uint256 sellerBalanceBefore = erc20Token.balanceOf(seller);
        auction.withdrawSellerProceeds();
        uint256 sellerBalanceAfter = erc20Token.balanceOf(seller);

        assertEq(
            sellerBalanceAfter,
            sellerBalanceBefore,
            "Seller should receive zero"
        );
    }

    // //////////////////////////
    // // Finalize Auction //
    // //////////////////////////

    function test_finalizeAuction_TransfersAssetToWinner() external {
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);

        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        assertEq(
            auction.winnerAssetRecipient(),
            bidder1,
            "Asset should be transferred to bidder1"
        );
    }

    function test_finalizeAuction_RevertWhen_AuctionNotYetEnded() external {
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);

        vm.expectRevert(EnglishAuction.AuctionNotYetEnded.selector);
        auction.finalizeAuction();
    }

    function test_finalizeAuctionWorksWithNoBids() external {
        // No one bids, just end the auction
        vm.warp(block.timestamp + duration + 1);

        // finalize
        auction.finalizeAuction();

        bool isFinalized = auction.isFinalized();
        assertEq(isFinalized, true, "Auction should be finalized");
        // No winner
        assertEq(
            auction.winnerAssetRecipient(),
            address(0),
            "No winner if no bids"
        );
    }

    function test_finalizeAuction_RevertWhen_AlreadyFinalized() external {
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);

        vm.warp(block.timestamp + duration + 1);
        auction.finalizeAuction();

        vm.expectRevert(EnglishAuction.AuctionAlreadyFinalized.selector);
        auction.finalizeAuction();
    }

    // //////////////////////////
    // // Anti-Sniping Tests   //
    // //////////////////////////

    function test_placeBidExtendsAuctionNearEnd() external {
        // Move close to the end
        uint256 endTimeBefore = auction.getEndTime();
        vm.warp(endTimeBefore - (extensionThreshold - 1));

        // Place a bid to trigger extension
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);

        uint256 endTimeAfter = auction.getEndTime();
        assertEq(
            endTimeAfter,
            endTimeBefore + extensionPeriod,
            "Should extend the auction end time"
        );
    }

    function test_placeBidDoesNotExtendWhenNotWithinThreshold() external {
        // Warp at the threshold(should not extend)
        uint256 endTimeBefore = auction.getEndTime();
        vm.warp(endTimeBefore - extensionThreshold);

        // Place a bid
        vm.startPrank(bidder1);
        erc20Token.approve(address(auction), 2 ether);
        auction.placeErc20Bid(2 ether);

        // Should not extend
        uint256 endTimeAfter = auction.getEndTime();
        assertEq(endTimeAfter, endTimeBefore, "No extension should occur");
    }

    function test_placeBidDoesNotExtendWhenThresholdIsZero() external {
        // Deploy a new auction with zero threshold
        MockEnglishAuction noExtendAuction = new MockEnglishAuction(
            seller,
            reservePrice,
            startTime,
            duration,
            0,
            extensionPeriod,
            address(erc20Token)
        );
        uint256 endTimeBefore = noExtendAuction.getEndTime();

        // Warp close to end
        vm.warp(endTimeBefore - 1);

        vm.startPrank(bidder1);
        erc20Token.approve(address(noExtendAuction), 2 ether);
        noExtendAuction.placeErc20Bid(2 ether);

        // Check no extension
        uint256 endTimeAfter = noExtendAuction.getEndTime();
        assertEq(
            endTimeAfter,
            endTimeBefore,
            "No extension if threshold is zero"
        );
    }

    function test_placeBidDoesNotExtendWhenExtensionPeriodIsZero() external {
        // Deploy a new auction with zero extension period
        MockEnglishAuction noExtendAuction = new MockEnglishAuction(
            seller,
            reservePrice,
            startTime,
            duration,
            extensionThreshold,
            0,
            address(erc20Token)
        );
        uint256 endTimeBefore = noExtendAuction.getEndTime();

        // Warp close to end
        vm.warp(endTimeBefore - 1);

        vm.startPrank(bidder1);
        erc20Token.approve(address(noExtendAuction), 2 ether);
        noExtendAuction.placeErc20Bid(2 ether);
        vm.stopPrank();

        // Check no extension
        uint256 endTimeAfter = noExtendAuction.getEndTime();
        assertEq(
            endTimeAfter,
            endTimeBefore,
            "No extension if extension period is zero"
        );
    }

    // //////////////////////////
    // // Increment Tests      //
    // //////////////////////////

    function test_placeBidWithIncrement_RevertWhen_BidNotHighEnough() external {
        // Deploy auction with 10 % increment requirement
        MockEnglishAuctionWithIncrement incrementAuction = new MockEnglishAuctionWithIncrement(
                seller,
                reservePrice,
                startTime,
                duration,
                extensionThreshold,
                extensionPeriod,
                address(erc20Token),
                10 // 10% increment
            );

        vm.startPrank(bidder1);
        erc20Token.approve(address(incrementAuction), 2 ether);
        incrementAuction.placeErc20Bid(2 ether);
        vm.stopPrank();

        // Bidder2 tries to outbid with only 2.1 ether (less than 10% increment over 2 ether)
        // 10% of 2 ether is 0.2 ether, so must be at least 2.2 ether
        vm.prank(bidder2);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.BidNotHighEnough.selector,
                2.1 ether,
                2.2 ether
            )
        );
        incrementAuction.placeErc20Bid(2.1 ether);
    }

    function test_placeBidWithIncrement_Works() external {
        // Deploy auction with 10 % increment requirement
        MockEnglishAuctionWithIncrement incrementAuction = new MockEnglishAuctionWithIncrement(
                seller,
                reservePrice,
                startTime,
                duration,
                extensionThreshold,
                extensionPeriod,
                address(erc20Token),
                10 // 10% increment
            );

        vm.startPrank(bidder1);
        erc20Token.approve(address(incrementAuction), 2 ether);
        incrementAuction.placeErc20Bid(2 ether);
        vm.stopPrank();

        // Bidder2 places a valid bid (2.5 ether meets 10% increment)
        vm.startPrank(bidder2);
        erc20Token.approve(address(incrementAuction), 2.5 ether);
        incrementAuction.placeErc20Bid(2.5 ether);
        vm.stopPrank();

        assertEq(
            incrementAuction.getHighestBidder(),
            bidder2,
            "Bidder2 should now be highest bidder"
        );
        assertEq(
            incrementAuction.getHighestBid(),
            2.5 ether,
            "Highest bid should be updated"
        );
    }
}
