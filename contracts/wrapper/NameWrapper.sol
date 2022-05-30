//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./ERC1155Fuse.sol";
import "./Controllable.sol";
import "./INameWrapper.sol";
import "./IMetadataService.sol";
import "../registry/ENS.sol";
import "../ethregistrar/IBaseRegistrar.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./BytesUtil.sol";

error Unauthorised(bytes32 node, address addr);
error NameNotFound();
error IncompatibleParent();
error IncompatibleName(bytes name);
error IncorrectTokenType();
error LabelMismatch(bytes32 labelHash, bytes32 expectedLabelhash);
error LabelTooShort();
error LabelTooLong(string label);
error IncorrectTargetOwner(address owner);
error InvalidExpiry(bytes32 node, uint64 expiry);

contract NameWrapper is
    Ownable,
    ERC1155Fuse,
    INameWrapper,
    Controllable,
    IERC721Receiver
{
    using BytesUtils for bytes;
    ENS public immutable override ens;
    IBaseRegistrar public immutable override registrar;
    IMetadataService public override metadataService;
    mapping(bytes32 => bytes) public override names;

    bytes32 private constant ETH_NODE =
        0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;
    bytes32 private constant ROOT_NODE =
        0x0000000000000000000000000000000000000000000000000000000000000000;

    uint64 private constant MAX_EXPIRY = 0xffffffffffffffff;

    constructor(
        ENS _ens,
        IBaseRegistrar _registrar,
        IMetadataService _metadataService
    ) {
        ens = _ens;
        registrar = _registrar;
        metadataService = _metadataService;

        /* Burn PARENT_CANNOT_CONTROL and CANNOT_UNWRAP fuses for ROOT_NODE and ETH_NODE */

        _setData(
            uint256(ETH_NODE),
            address(0),
            uint32(PARENT_CANNOT_CONTROL | CANNOT_UNWRAP),
            MAX_EXPIRY
        );
        _setData(
            uint256(ROOT_NODE),
            address(0),
            uint32(PARENT_CANNOT_CONTROL | CANNOT_UNWRAP),
            MAX_EXPIRY
        );
        names[ROOT_NODE] = "\x00";
        names[ETH_NODE] = "\x03eth\x00";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Fuse, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(INameWrapper).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /* ERC1155 */

    function ownerOf(uint256 id)
        public
        view
        override(ERC1155Fuse, INameWrapper)
        returns (address owner)
    {
        return super.ownerOf(id);
    }

    /* Metadata service */

    /**
     * @notice Set the metadata service. only admin can do this
     */

    function setMetadataService(IMetadataService _newMetadataService)
        public
        onlyOwner
    {
        metadataService = _newMetadataService;
    }

    /**
     * @notice Get the metadata uri
     * @return String uri of the metadata service
     */

    function uri(uint256 tokenId) public view override returns (string memory) {
        return metadataService.uri(tokenId);
    }

    /**
     * @notice Checks if msg.sender is the owner or approved by the owner of a name
     * @param node namehash of the name to check
     */

    modifier onlyTokenOwner(bytes32 node) {
        if (!isTokenOwnerOrApproved(node, msg.sender)) {
            revert Unauthorised(node, msg.sender);
        }

        _;
    }

    /**
     * @notice Checks if owner or approved by owner
     * @param node namehash of the name to check
     * @param addr which address to check permissions for
     * @return whether or not is owner or approved
     */

    function isTokenOwnerOrApproved(bytes32 node, address addr)
        public
        view
        override
        returns (bool)
    {
        address owner = ownerOf(uint256(node));
        return owner == addr || isApprovedForAll(owner, addr);
    }

    /**
     * @notice Gets fuse permissions for a specific name
     * @dev Fuses are represented by a uint32 where each permission is represented by 1 bit
     *      The interface has predefined fuses for all registry permissions, but additional
     *      fuses can be added for other use cases
     *      Also returns expiry, which is when the fuses are set to expire.
     * @param node namehash of the name to check
     * @return fuses A number that represents the permissions a name has
     * @return expiry Unix time of when the name expires and fuses are to expire
     */
    function getFuses(bytes32 node)
        public
        view
        override
        returns (
            uint32 fuses,
            uint64 expiry
        )
    {
        bytes memory name = names[node];
        if (name.length == 0) {
            revert NameNotFound();
        }
        (, fuses, expiry) = getData(uint256(node));
    }

    /**
     * @notice Wraps a .eth domain, creating a new token and sending the original ERC721 token to this *         contract
     * @dev Can be called by the owner of the name in the .eth registrar or an authorised caller on the *      registrar
     * @param label label as a string of the .eth domain to wrap
     * @param fuses initial fuses to set
     * @param wrappedOwner Owner of the name in this contract
     */

    function wrapETH2LD(
        string calldata label,
        address wrappedOwner,
        uint32 fuses,
        uint64 expiry,
        address resolver
    ) public override {
        uint256 tokenId = uint256(keccak256(bytes(label)));
        address registrant = registrar.ownerOf(tokenId);
        if (
            registrant != msg.sender &&
            !isApprovedForAll(registrant, msg.sender) &&
            !registrar.isApprovedForAll(registrant, msg.sender)
        ) {
            revert Unauthorised(
                _makeNode(ETH_NODE, bytes32(tokenId)),
                msg.sender
            );
        }

        // transfer the token from the user to this contract
        registrar.transferFrom(registrant, address(this), tokenId);

        // transfer the ens record back to the new owner (this contract)
        registrar.reclaim(tokenId, address(this));

        _wrapETH2LD(label, wrappedOwner, fuses, expiry, resolver);
    }

    /**
     * @dev Registers a new .eth second-level domain and wraps it.
     *      Only callable by authorised controllers.
     * @param label The label to register (Eg, 'foo' for 'foo.eth').
     * @param wrappedOwner The owner of the wrapped name.
     * @param duration The duration, in seconds, to register the name for.
     * @param resolver The resolver address to set on the ENS registry (optional).
     * @return expiry The expiry date of the new name, in seconds since the Unix epoch.
     */
    function registerAndWrapETH2LD(
        string calldata label,
        address wrappedOwner,
        uint256 duration,
        address resolver,
        uint32 fuses
    ) external override onlyController returns (uint256 expiry) {
        uint256 tokenId = uint256(keccak256(bytes(label)));

        expiry = registrar.register(tokenId, address(this), duration);
        _wrapETH2LD(label, wrappedOwner, fuses, uint64(expiry), resolver);
    }

    /**
     * @dev Renews a .eth second-level domain.
     *      Only callable by authorised controllers.
     * @param tokenId The hash of the label to register (eg, `keccak256('foo')`, for 'foo.eth').
     * @param duration The number of seconds to renew the name for.
     * @return expires The expiry date of the name, in seconds since the Unix epoch.
     */
    function renew(uint256 tokenId, uint256 duration)
        external
        override
        onlyController
        returns (uint256 expires)
    {
        return registrar.renew(tokenId, duration);
    }

    /**
     * @notice Wraps a non .eth domain, of any kind. Could be a DNSSEC name vitalik.xyz or a subdomain
     * @dev Can be called by the owner in the registry or an authorised caller in the registry
     * @param name The name to wrap, in DNS format
     * @param fuses initial fuses to set represented as a number. Check getFuses() for more info
     * @param wrappedOwner Owner of the name in this contract
     */

    function wrap(
        bytes calldata name,
        address wrappedOwner,
        uint32 fuses,
        address resolver
    ) public override {
        (bytes32 labelhash, uint256 offset) = name.readLabel(0);
        bytes32 parentNode = name.namehash(offset);
        bytes32 node = _makeNode(parentNode, labelhash);

        if (parentNode == ETH_NODE) {
            revert IncompatibleParent();
        }

        address owner = ens.owner(node);

        if (
            owner != msg.sender &&
            !isApprovedForAll(owner, msg.sender) &&
            !ens.isApprovedForAll(owner, msg.sender)
        ) {
            revert Unauthorised(node, msg.sender);
        }

        if (resolver != address(0)) {
            ens.setResolver(node, resolver);
        }

        ens.setOwner(node, address(this));

        _wrap(node, name, wrappedOwner, fuses, 0);
    }

    /**
     * @notice Unwraps a .eth domain. e.g. vitalik.eth
     * @dev Can be called by the owner in the wrapper or an authorised caller in the wrapper
     * @param labelhash labelhash of the .eth domain
     * @param newRegistrant sets the owner in the .eth registrar to this address
     * @param newController sets the owner in the registry to this address
     */

    function unwrapETH2LD(
        bytes32 labelhash,
        address newRegistrant,
        address newController
    ) public override onlyTokenOwner(_makeNode(ETH_NODE, labelhash)) {
        _unwrap(_makeNode(ETH_NODE, labelhash), newController);
        registrar.transferFrom(
            address(this),
            newRegistrant,
            uint256(labelhash)
        );
    }

    /**
     * @notice Unwraps a non .eth domain, of any kind. Could be a DNSSEC name vitalik.xyz or a subdomain
     * @dev Can be called by the owner in the wrapper or an authorised caller in the wrapper
     * @param parentNode parent namehash of the name to wrap e.g. vitalik.xyz would be namehash('xyz')
     * @param labelhash labelhash of the .eth domain
     * @param newController sets the owner in the registry to this address
     */

    function unwrap(
        bytes32 parentNode,
        bytes32 labelhash,
        address newController
    ) public override onlyTokenOwner(_makeNode(parentNode, labelhash)) {
        if (parentNode == ETH_NODE) {
            revert IncompatibleParent();
        }
        _unwrap(_makeNode(parentNode, labelhash), newController);
    }

    function setFuses(bytes32 parentNode, bytes32 labelhash, uint32 fuses) onlyTokenOwner(_makeNode(parentNode, labelhash)) public {
        bytes32 node = _makeNode(parentNode, labelhash);
        (address owner, uint32 oldFuses, uint64 expiry) = _getData(node);

        if(fuses & PARENT_CANNOT_CONTROL != 0){
            revert Unauthorised(parentNode, msg.sender);
        }

        (,, uint64 maxExpiry) = getData(uint256(parentNode));
        if(expiry > maxExpiry){
            // check if parent has burned CANNOT_UNWRAP when you're burning any fuses
            // check if parent is still wrapped when extending expiry
            expiry = maxExpiry;
        }
        fuses |= oldFuses;
        _setFuses(node, owner, fuses, expiry);
    }

    function setChildFuses(bytes32 parentNode, bytes32 labelhash, uint32 fuses, uint64 expiry) public {
        bytes32 node = _makeNode(parentNode, labelhash);
        (address owner, uint32 oldFuses, uint64 oldExpiry) = _getData(node);
        uint64 maxExpiry;
        if(parentNode == ETH_NODE ){
            if(!isTokenOwnerOrApproved(node, msg.sender)){
                revert Unauthorised(node, msg.sender);
            }
            maxExpiry = uint64(registrar.nameExpires(uint256(labelhash)));
        } else {
            if(!isTokenOwnerOrApproved(parentNode, msg.sender)){
                revert Unauthorised(node, msg.sender);
            }

            if(oldFuses & PARENT_CANNOT_CONTROL != 0 && fuses | oldFuses != oldFuses) {
                revert Unauthorised(node, msg.sender);
            }

            (,,maxExpiry) = getData(uint256(parentNode));
        }
        if(expiry > maxExpiry){
            expiry = maxExpiry;
        }
        fuses |= oldFuses;
        _setFuses(node, owner, fuses, expiry);
    }

    /**
     * @notice Sets the subdomain owner in the registry and then wraps the subdomain
     * @param parentNode parent namehash of the subdomain
     * @param label label of the subdomain as a string
     * @param newOwner newOwner in the registry
     * @param fuses initial fuses for the wrapped subdomain
     */

    function setSubnodeOwner(
        bytes32 parentNode,
        string calldata label,
        address newOwner,
        uint32 fuses,
        uint64 expiry
    )
        public
        onlyTokenOwner(parentNode)
        canCallSetSubnodeOwner(parentNode, keccak256(bytes(label)))
        returns (bytes32 node)
    {

        bytes32 labelhash = keccak256(bytes(label));
        node = _makeNode(parentNode, labelhash);
        _checkExpiration(parentNode, node, expiry);

        if (ens.owner(node) != address(this)) {
            ens.setSubnodeOwner(parentNode, labelhash, address(this));
            _addLabelAndWrap(parentNode, node, label, newOwner, fuses, expiry);
        } else {
            _transferAndBurnFuses(node, newOwner, fuses, expiry);
        }
    }

    /**
     * @notice Sets the subdomain owner in the registry with records and then wraps the subdomain
     * @param parentNode parent namehash of the subdomain
     * @param label label of the subdomain as a string
     * @param newOwner newOwner in the registry
     * @param resolver resolver contract in the registry
     * @param ttl ttl in the regsitry
     * @param fuses initial fuses for the wrapped subdomain
     * @param expiry expiry date for the domain
     */

    function setSubnodeRecord(
        bytes32 parentNode,
        string memory label,
        address newOwner,
        address resolver,
        uint64 ttl,
        uint32 fuses,
        uint64 expiry
    )
        public
        onlyTokenOwner(parentNode)
        canCallSetSubnodeOwner(parentNode, keccak256(bytes(label)))
    {
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = _makeNode(parentNode, labelhash);
        _checkExpiration(parentNode, node, expiry);
        if (ens.owner(node) != address(this)) {
            ens.setSubnodeRecord(
                parentNode,
                labelhash,
                address(this),
                resolver,
                ttl
            );
            _addLabelAndWrap(parentNode, node, label, newOwner, fuses, expiry);
        } else {
            ens.setSubnodeRecord(
                parentNode,
                labelhash,
                address(this),
                resolver,
                ttl
            );
            _transferAndBurnFuses(node, newOwner, fuses, expiry);
        }
    }

    /**
     * @notice Sets records for the name in the ENS Registry
     * @param node namehash of the name to set a record for
     * @param owner newOwner in the registry
     * @param resolver the resolver contract
     * @param ttl ttl in the registry
     */

    function setRecord(
        bytes32 node,
        address owner,
        address resolver,
        uint64 ttl
    )
        public
        override
        onlyTokenOwner(node)
        operationAllowed(
            node,
            CANNOT_TRANSFER | CANNOT_SET_RESOLVER | CANNOT_SET_TTL
        )
    {
        ens.setRecord(node, owner, resolver, ttl);
    }

    /**
     * @notice Sets resolver contract in the registry
     * @param node namehash of the name
     * @param resolver the resolver contract
     */

    function setResolver(bytes32 node, address resolver)
        public
        override
        onlyTokenOwner(node)
        operationAllowed(node, CANNOT_SET_RESOLVER)
    {
        ens.setResolver(node, resolver);
    }

    /**
     * @notice Sets TTL in the registry
     * @param node namehash of the name
     * @param ttl TTL in the registry
     */

    function setTTL(bytes32 node, uint64 ttl)
        public
        override
        onlyTokenOwner(node)
        operationAllowed(node, CANNOT_SET_TTL)
    {
        ens.setTTL(node, ttl);
    }

    /**
     * @dev Allows an operation only if none of the specified fuses are burned.
     * @param node The namehash of the name to check fuses on.
     * @param fuseMask A bitmask of fuses that must not be burned.
     */
    
    modifier operationAllowed(bytes32 node, uint32 fuseMask) {
        (, uint32 fuses, uint64 expiry) = getData(uint256(node));
        if (fuses & fuseMask != 0 && expiry > block.timestamp) {
            revert OperationProhibited(node);
        }
        _;
    }

    /**
     * @notice Check whether a name can call setSubnodeOwner/setSubnodeRecord
     * @dev Checks both canCreateSubdomain and canReplaceSubdomain and whether not they have been burnt
     *      and checks whether the owner of the subdomain is 0x0 for creating or already exists for
     *      replacing a subdomain. If either conditions are true, then it is possible to call
     *      setSubnodeOwner
     * @param node namehash of the name to check
     * @param labelhash labelhash of the name to check
     */

    modifier canCallSetSubnodeOwner(bytes32 node, bytes32 labelhash) {
        bytes32 subnode = _makeNode(node, labelhash);
        address owner = ens.owner(subnode);

        if (owner == address(0)) {
            (, uint96 fuses,) = getData(uint256(node));
            if (fuses & CANNOT_CREATE_SUBDOMAIN != 0) {
                revert OperationProhibited(node);
            }
        } else {
            (, uint96 subnodeFuses,) = getData(uint256(subnode));
            if (subnodeFuses & PARENT_CANNOT_CONTROL != 0) {
                revert OperationProhibited(node);
            }
        }

        _;
    }

    /**
     * @notice Checks all Fuses in the mask are burned for the node
     * @param node namehash of the name
     * @param fuseMask the fuses you want to check
     * @return Boolean of whether or not all the selected fuses are burned
     */

    function allFusesBurned(bytes32 node, uint32 fuseMask)
        public
        view
        override
        returns (bool)
    {
        (, uint32 fuses,) = getData(uint256(node));
        return fuses & fuseMask == fuseMask;
    }

    function onERC721Received(
        address to,
        address,
        uint256 tokenId,
        bytes calldata data
    ) public override returns (bytes4) {
        //check if it's the eth registrar ERC721
        if (msg.sender != address(registrar)) {
            revert IncorrectTokenType();
        }

        (
            string memory label,
            address owner,
            uint32 fuses,
            uint64 expiry,
            address resolver
        ) = abi.decode(data, (string, address, uint32, uint64, address));

        bytes32 labelhash = bytes32(tokenId);
        bytes32 labelhashFromData = keccak256(bytes(label));

        if (labelhashFromData != labelhash) {
            revert LabelMismatch(labelhashFromData, labelhash);
        }

        // transfer the ens record back to the new owner (this contract)
        registrar.reclaim(uint256(labelhash), address(this));

        _wrapETH2LD(label, owner, fuses, expiry, resolver);

        return IERC721Receiver(to).onERC721Received.selector;
    }

    /***** Internal functions */

    function _canTransfer(uint32 fuses) internal pure override returns (bool) {
        return fuses & CANNOT_TRANSFER == 0;
    }

    function _makeNode(bytes32 node, bytes32 labelhash)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(node, labelhash));
    }

    function _addLabel(string memory label, bytes memory name)
        internal
        pure
        returns (bytes memory ret)
    {
        if (bytes(label).length < 1) {
            revert LabelTooShort();
        }
        if (bytes(label).length > 255) {
            revert LabelTooLong(label);
        }
        return abi.encodePacked(uint8(bytes(label).length), label, name);
    }

    function _mint(
        bytes32 node,
        address wrappedOwner,
        uint32 fuses,
        uint64 expiry
    ) internal override {
        address oldWrappedOwner = ownerOf(uint256(node));
        if (oldWrappedOwner != address(0)) {
            // burn and unwrap old token of old owner
            _burn(uint256(node));
            emit NameUnwrapped(node, address(0));
        }
        super._mint(node, wrappedOwner, fuses, expiry);
    }

    function _wrap(
        bytes32 node,
        bytes memory name,
        address wrappedOwner,
        uint32 fuses,
        uint64 expiry
    ) internal {
        names[node] = name;

        _mint(node, wrappedOwner, fuses, expiry);

        emit NameWrapped(node, name, wrappedOwner, fuses, expiry);
    }

    function _addLabelAndWrap(
        bytes32 parentNode,
        bytes32 node,
        string memory label,
        address newOwner,
        uint32 fuses,
        uint64 expiry
    ) internal {
        bytes memory name = _addLabel(label, names[parentNode]);
        _wrap(node, name, newOwner, fuses, expiry);
    }

    function _transferAndBurnFuses(
        bytes32 node,
        address newOwner,
        uint32 fuses,
        uint64 expiry
    ) internal {
        (address owner, ,) = getData(uint256(node));
        _transfer(owner, newOwner, uint256(node), 1, "");
        _burnFuses(node, fuses, expiry);
        // deal with expiry
    }

    function _checkExpiration(bytes32 parentNode, bytes32 node, uint64 expiry) internal{
        (,,uint64 oldExpiry) = getData(uint256(node));
        (,,uint64 maxExpiry) = getData(uint256(parentNode));

        // check it's not going backwards or is more than the parent expiry
        if(expiry < oldExpiry || expiry > maxExpiry) {
            revert InvalidExpiry();
        }
    }

    

    function _wrapETH2LD(
        string memory label,
        address wrappedOwner,
        uint32 fuses,
        uint64 expiry,
        address resolver
    ) private returns (bytes32 labelhash) {
        // mint a new ERC1155 token with fuses
        // Set PARENT_CANNOT_REPLACE to reflect wrapper + registrar control over the 2LD
        labelhash = keccak256(bytes(label));
        bytes32 node = _makeNode(ETH_NODE, labelhash);
        _addLabelAndWrap(
            ETH_NODE,
            node,
            label,
            wrappedOwner,
            fuses | PARENT_CANNOT_CONTROL,
            expiry
        );
        if (resolver != address(0)) {
            ens.setResolver(node, resolver);
        }
    }

    function _unwrap(bytes32 node, address newOwner) private {
        if (newOwner == address(0x0) || newOwner == address(this)) {
            revert IncorrectTargetOwner(newOwner);
        }

        if (allFusesBurned(node, CANNOT_UNWRAP)) {
            revert OperationProhibited(node);
        }

        // burn token and fuse data
        _burn(uint256(node));
        ens.setOwner(node, newOwner);

        emit NameUnwrapped(node, newOwner);
    }

    function _setFuses(bytes32 node, address owner, uint32 fuses, uint64 expiry) internal {
        _setData(node, owner, fuses, expiry);
        emit FusesSet(node, fuses, expiry);
    }

    function _setData(
        bytes32 node,
        address owner,
        uint32 fuses,
        uint64 expiry
    ) internal {
        // Other than PARENT_CANNOT_CONTROL, no other fuse can be set without CANNOT_UNWRAP
        if (fuses & ~PARENT_CANNOT_CONTROL != 0 && fuses & CANNOT_UNWRAP == 0) {
            revert OperationProhibited(bytes32(node));
        }

        super._setData(uint256(node), owner, fuses, expiry);
    }
}
