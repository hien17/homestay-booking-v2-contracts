// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {DataConsumerV3} from "../data-consumer-chainlink/main.sol";


contract HomestayNFT is ERC721, Ownable {
    using Counters for Counters.Counter;
    using Address for address;
    using SafeMath for uint256;
    Counters.Counter private _tokenIdCounter;

    DataConsumerV3 dataConsumerV3;
    uint256 public immutable _startTime;                           // time create contract
    bool[] _roomValidity;                                          // array of validity of rooms [room id] (validity of room is decided by owner of homestay)
    uint256 public _noRooms;                                       // number of rooms when create contract
    uint256[] public _price;                                       // price of first 2 hours, every hour after first 2 hours, every day, every month. 

    uint256 public _version;                                        // curent version of policy
    uint256[] public _minTimeToCancelPrepaid;                       // minimum time to cancel prepaid booking
    uint256[] public _minTimeToCancelDeposit;                       // minimum time to cancel deposit booking
    uint256[] public _percentDeposit;                               // percent deposit for deposit booking   

    mapping (address=>uint256) public _noNftOfRenter;              // number of nfts (rental contract) of renter [address renter]
    uint256[] public _nftsOfProvider;                              // array of nfts (rental contract of users) of provider [token id]
    mapping (address=>uint256) public _noNftOfProvider;            // number of nfts of provider [address provider]
    mapping(address=>uint256[]) public _nftsOfRenter;              // array of nfts of renter [address renter]
    mapping(address => bool) public _authorizedGateways; 

    event Mint(address indexed provider, address indexed renter, uint256 roomId, uint256 rentAmount, uint256 startTimestamp, uint256 endTimestamp, uint256 createTimestamp, uint256 indexed tokenId, bool isCancelled, bool isCheckedOut, uint256 version, bool isPrepaid, bool isPaidAll);
    event PayRemaining(uint256 indexed tokenId);
    event LogIoTDevice(uint256 indexed tokenId, uint256 deviceId, bool status, uint256 timestamp);
    event Checkout(uint256 indexed tokenId, uint256 indexed roomId, uint256 startTimestamp);
    event DataSent(string encryptedData, bytes32 hashedData);

    event ListNFT(address indexed from, uint256 tokenId, uint256 price);
    event UnlistNFT(address indexed from, uint256 tokenId);
    event BuyNFT(address indexed from, uint256 tokenId, uint256 price);
    event UpdateListingNFTPrice(uint256 tokenId, uint256 price);
    //rental contract between provider and renter (NFT)
    struct NFT{
        address provider;
        address renter;
        uint256 roomId; 
        uint256 rentAmount;
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 createTimestamp; 
        bool isCancelled;
        bool isCheckedOut;
        uint256 price;
        uint256 version;  
        bool isPrepaid;
        bool isPaidAll; // if isPrepaid false it means that this is deposit booking, so isPaidAll will be the flag to check if renter paid all or not 
    }
    
    mapping(uint256 => NFT) public _nfts;                           //all nfts that were created
    mapping(uint256 => string) public _logIoTdevices;       //all logIoTdevice that were created

    //constructor function: all rooms are valid (for use) and store time constructed.
    constructor(address dataConsumerV3Address,uint256 noRooms, uint256 firstTwoHourPrice, uint256 hourPrice, uint256 dayPrice, uint256 monthPrice) ERC721("HomestayNFT", "HNFT") Ownable() {
        dataConsumerV3 = DataConsumerV3(dataConsumerV3Address);
        _startTime = block.timestamp;
        _noRooms = noRooms;
        for (uint256 i = 0; i < noRooms; i++) {
            _roomValidity.push(true);
        }
        _price.push(firstTwoHourPrice);
        _price.push(hourPrice);
        _price.push(dayPrice);
        _price.push(monthPrice);
    }


    modifier onlyAuthorizedGateway() {
        require(_authorizedGateways[msg.sender], "Sender is not an authorized gateway");
        _;
    }

    modifier checkoutRequirement(uint256 tokenId) {
        require(_nfts[tokenId].isCancelled == false, "This contract has already been cancelled");
        require(_nfts[tokenId].isCheckedOut == false, "This contract has already been checked out");
        require(ownerOf(tokenId)!=address(0), "Token ID does not exist");
        require(msg.sender == ownerOf(tokenId) || (msg.sender == owner() && (block.timestamp>=_nfts[tokenId].endTimestamp)),"You must be a user want to check out or you must be owner and checkout contract after renting time of user");
        _;
    }

    // function to add an authorized gateway
    function addAuthorizedGateway(address gateway) external onlyOwner {
        _authorizedGateways[gateway] = true;
    }

    // function to remove an authorized gateway
    function removeAuthorizedGateway(address gateway) external onlyOwner {
        _authorizedGateways[gateway] = false;
    }

    // function to update new policy 
    function newPolicyVersion(uint256 minTimeToCancelPrepaid, uint256 minTimeToCancelDeposit, uint256 percentDeposit) public onlyOwner {
        _minTimeToCancelPrepaid.push(minTimeToCancelPrepaid);
        _minTimeToCancelDeposit.push(minTimeToCancelDeposit);
        _percentDeposit.push(percentDeposit);
        _version++;
    }

    //function change the number of room of homestay (in case want to expand homestay)
    function setNoRooms(uint256 noRooms) public {
        require(noRooms>_noRooms,"Number of rooms must be greater than at present");
        for (uint256 i = _noRooms; i < noRooms; i++) {
            _roomValidity[i] = true;
        }
        _noRooms = noRooms;
    }

    //functions about validity of rooms
    function getRoomValidity(uint256 roomId) public view returns(bool){
        return _roomValidity[roomId];
    }
    function getAllRoomsValidity() public view returns(bool[] memory){
        return _roomValidity;
    }
    function setRoomValidity(uint256 roomId, bool isValid) public onlyOwner {
        require(roomId>0, "Invalid room id");
        _roomValidity[roomId] = isValid;
    }
    function setMultipleRoomsValidity(uint256[] calldata roomIds,bool[] calldata isValid) public onlyOwner{
        //function to change validity of many rooms at one time
        require(roomIds.length == isValid.length, "Arrays length mismatch");
        for (uint256 i = 0; i < roomIds.length; i++) {
            _roomValidity[roomIds[i]] = isValid[i];
        }
    }

    //functions about price of renting a room according to 2 first hours, every hour after 2 first hours, every day, every month.
    function getPrice() public view returns(uint256[] memory){
        return _price;
    }

    function setPrice(uint256[4] calldata price) public onlyOwner {
        _price = price;
    }

    function getBnbPrice() public view returns (uint256) {
        return uint256(dataConsumerV3.getChainlinkDataFeedLatestAnswer());
    }
    function usdToBnb(uint256 amountUsd) public view returns(uint256 amountBnb) {
        uint256 bnbPrice = getBnbPrice();
        amountBnb = amountUsd*(1 ether)/bnbPrice*10**8*(1 wei);
    }
    function bnbToUsd(uint256 amountBnb) public view returns(uint256 amountUsd) {
        uint256 bnbPrice = getBnbPrice();
        amountUsd = amountBnb*bnbPrice/(1 ether * 10**8) + 1;
    }

    //mint a token (create a homestay contract by user)
    function safeMint(uint256 roomId, uint256 rentAmount, uint256 startTimestamp, uint256 endTimestamp, bool isPrepaid) public payable {
        require(_roomValidity[roomId]==true,"This room is not available");
        require(startTimestamp>block.timestamp,"Invalid start time");
        uint256 timeDiff = endTimestamp - startTimestamp;
        require(timeDiff > 0, "Invalid timestamps");

        uint256 tokenId = _tokenIdCounter.current();
        
        //rent amount for owner is decided by owner
        //if not the owner , the rent amount will be calculated (rent amount is calc followed by USD, but price is followed by Bnb price)
        if (msg.sender != owner()) {
            rentAmount = calculateRentAmount(timeDiff);
            if (isPrepaid)
                require(msg.value >= usdToBnb(rentAmount)* 1 wei, "Insufficient funds to mint prepaid NFT stay");
            else 
                require(msg.value >= usdToBnb(rentAmount*_percentDeposit[_version-1]/100)* 1 wei, "Insufficient funds to mint deposit NFT stay");
        }
        uint256 price = usdToBnb(rentAmount);
        _nfts[tokenId] = NFT(owner(),msg.sender,roomId,rentAmount,startTimestamp,endTimestamp,block.timestamp,false,false,price,_version-1,isPrepaid,false);
        _nftsOfProvider.push(tokenId);
        _nftsOfRenter[msg.sender].push(tokenId);
        _tokenIdCounter.increment();
        _noNftOfProvider[owner()]++;
        _noNftOfRenter[msg.sender]++;
        
        _safeMint(msg.sender,tokenId);
        emit Mint(owner(),msg.sender,roomId,rentAmount,startTimestamp,endTimestamp,block.timestamp,tokenId,false,false,_version-1,isPrepaid,false);
    } 
    function calculateRentAmount(uint256 timeDiff) public view returns (uint256){
        uint256 calRentAmount;
        if (timeDiff <= 2 hours) {
            calRentAmount = _price[0];
        } else if (timeDiff > 2 hours && timeDiff < 24 hours) {                                 // Calculate price for hours after the first 2 hours
            uint256 extraHours = (timeDiff - 2 hours + 3599) / 1 hours;                         // Round up to the nearest hour
            calRentAmount = _price[0] + (extraHours * _price[1]);
        } else if (timeDiff >= 24 hours && timeDiff < 720 hours) {                              // Calculate price for days
            uint256 numDays = timeDiff / 1 days;                                                // Round up to the nearest day
            uint256 remainingHours = (timeDiff % 1 days + 3599) / 1 hours;
            calRentAmount = (numDays * _price[2]) + (remainingHours * _price[1]);
        } else {                                                                                // Calculate price for months, days, and remaining hours
            uint256 numMonths = timeDiff / 30 days;                                             // Round up to the nearest month
            uint256 remainingDays = (timeDiff % 30 days) / 1 days;                              // Round up to the nearest day
            uint256 remainingHours = ((timeDiff % 30 days) % 1 days + 3599) / 1 hours;          // Round up to the nearest hour
            calRentAmount = (numMonths * _price[3]) + (remainingDays * _price[2]) + (remainingHours * _price[1]);
        }
        return calRentAmount;
    }

    function payRemaining(uint256 tokenId) public payable {
        require(ownerOf(tokenId)!=address(0), "Token ID does not exist");
        require(_nfts[tokenId].isPrepaid == false, "This is prepaid booking");
        require(_nfts[tokenId].isPaidAll == false, "This contract has already been paid all");
        require(msg.value >= usdToBnb(_nfts[tokenId].rentAmount*(100-_percentDeposit[_version-1])/100)* 1 wei, "Insufficient funds to pay remaining");
        _nfts[tokenId].isPaidAll = true;
        emit PayRemaining(tokenId);
    }

    //cancel contract and mark as isCancellled
    function cancelContract(uint256 tokenId) public {
        require(_nfts[tokenId].isCancelled == false, "This contract has already been cancelled");
        require(msg.sender==ownerOf(tokenId),"You are not room's owner");
        if (_nfts[tokenId].isPrepaid) 
            require(block.timestamp < _nfts[tokenId].startTimestamp - _minTimeToCancelPrepaid[_version-1], "You cannot cancel this prepaid contract");
        else 
            require(block.timestamp < _nfts[tokenId].startTimestamp - _minTimeToCancelDeposit[_version-1], "You cannot cancel this deposit contract");
        _noNftOfProvider[owner()]--;
        _noNftOfRenter[msg.sender]--;
        _nfts[tokenId].isCancelled = true;
        if (_nfts[tokenId].isPrepaid) {
            payable(owner()).transfer(usdToBnb(_nfts[tokenId].rentAmount)*1 wei);
        } else {
            payable(owner()).transfer(usdToBnb(_nfts[tokenId].rentAmount*_percentDeposit[_version-1]/100)*1 wei);
        }
    }

    //get info of a NFT (a rental contract)
    function getNFTInfo(uint256 tokenId) public view returns (
        address provider,
        address renter,
        uint256 roomId,
        uint256 rentAmount,
        uint256 startTimestamp,
        uint256 endTimestamp,
        uint256 createTimestamp,
        bool isCancelled,
        bool isCheckedOut
    ) {
        require(ownerOf(tokenId)!=address(0), "Token ID does not exist");
        NFT memory nft = _nfts[tokenId];
        return (nft.provider,nft.renter,nft.roomId,nft.rentAmount,nft.startTimestamp,nft.endTimestamp,nft.createTimestamp,nft.isCancelled,nft.isCheckedOut);
    }

    //functions return array of nfts of renter/provider

    function getNftsIdOfRenter() public view returns(uint256[] memory) {
        return _nftsOfRenter[msg.sender];
    }
    function getNftsIdOfProvider() public view returns(uint256[] memory) {
        return _nftsOfProvider;
    }

    //function that store log of iot devices when checkout 
    function checkout(uint256 tokenId) public checkoutRequirement((tokenId)){
        _nfts[tokenId].isCheckedOut = true;
        payable(owner()).transfer(usdToBnb(_nfts[tokenId].rentAmount)*1 wei);
        emit Checkout(tokenId,_nfts[tokenId].roomId,_nfts[tokenId].startTimestamp);
    }

    //function that allows iot gateway send log of iot devices
    function sendData(uint256 tokenId, string memory encryptedData, bytes32 hashedData) public onlyAuthorizedGateway {
        _logIoTdevices[tokenId] = encryptedData;
        emit DataSent(encryptedData, hashedData);
    }

    //function that return log iot devices of a rental contract
    function getLogsForToken(uint256 tokenId) public view returns (string memory) {
        require(ownerOf(tokenId)!=address(0), "Token ID does not exist");
        return _logIoTdevices[tokenId];
    }

    //function that return info of policy
    function getPolicyByVersion(uint256 version) public view returns (uint256[3] memory) {
        return [_minTimeToCancelPrepaid[version], _minTimeToCancelDeposit[version], _percentDeposit[version]];
    }

    //function that return info of the latest policy
    function getLatestPolicy() public view returns (uint256[3] memory) {
        return [_minTimeToCancelPrepaid[_version-1], _minTimeToCancelDeposit[_version-1], _percentDeposit[_version-1]];
    }


    function tokenURI(uint256 tokenId) public view  override(ERC721) returns (string memory){
        return super.tokenURI(tokenId);
    }

    function getTime() public view returns(uint){
        return block.timestamp-_startTime;
    }

    // SPDX-IGNORE
    function emitListNFT(address from,uint256 tokenId,uint256 price) public  {
        emit ListNFT(from, tokenId, price);
    }

    // SPDX-IGNORE
    function emitBuyNFT(address from, uint256 tokenId, uint256 price) public  {
        emit BuyNFT(from, tokenId, price);
    }

    // SPDX-IGNORE
    function emitUnlistNFT(address from, uint256 tokenId) public  {
        emit UnlistNFT(from, tokenId);
    }

    // SPDX-IGNORE
    function emitUpdateListingNFTPrice(uint256 tokenId,uint256 price) public  {
        emit UpdateListingNFTPrice(tokenId, price);
    }

    function getBalance() public view returns(uint256){
        return address(this).balance;
    }
}