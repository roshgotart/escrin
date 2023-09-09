// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {randomBytes} from "../../Utilities.sol";
import {IIdentityRegistry, Permits} from "./IIdentityRegistry.sol";
import {IPermitter} from "./IPermitter.sol";
import {IdentityId, InterfaceUnsupported, Unauthorized} from "./Types.sol";

contract IdentityRegistry is IIdentityRegistry, ERC165 {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Permits for Permit;

    struct Registration {
        bool registered;
        address registrant;
    }

    mapping(IdentityId => Registration) private registrations;
    mapping(IdentityId => address) private proposedRegistrants;

    mapping(IdentityId => IPermitter) private permitters;

    mapping(IdentityId => EnumerableSet.AddressSet) private permittedAccounts;
    mapping(address => mapping(IdentityId => Permit)) private permits;

    modifier onlyRegistrant(IdentityId id) {
        if (msg.sender != registrations[id].registrant) revert Unauthorized();
        _;
    }

    modifier onlyPermitter(IdentityId id) {
        if (msg.sender != address(permitters[id])) revert Unauthorized();
        _;
    }

    function createIdentity(address permitter, bytes calldata pers)
        external
        override
        returns (IdentityId id)
    {
        id = IdentityId.wrap(uint256(bytes32(randomBytes(32, pers))));
        require(!registrations[id].registered, "unlucky");
        registrations[id] = Registration({registered: true, registrant: msg.sender});
        permitters[id] = _requireIsPermitter(permitter);
        _whenIdentityCreated(id, pers);
        emit IdentityCreated(id);
    }

    function destroyIdentity(IdentityId id) external override onlyRegistrant(id) {
        delete registrations[id].registrant;
        delete proposedRegistrants[id];
        delete permitters[id];
        EnumerableSet.AddressSet storage permitted = permittedAccounts[id];
        for (uint256 i; i < permitted.length(); i++) {
            address account = permitted.at(i);
            delete permits[account][id];
            permitted.remove(account);
        }
        _whenIdentityDestroyed(id);
        emit IdentityDestroyed(id);
    }

    function setPermitter(IdentityId id, address permitter) external override onlyRegistrant(id) {
        permitters[id] = _requireIsPermitter(permitter);
        emit PermitterChanged(id);
    }

    function proposeRegistrationTransfer(IdentityId id, address to)
        external
        override
        onlyRegistrant(id)
    {
        proposedRegistrants[id] = to;
        emit RegistrationTransferProposed(id, to);
    }

    function acceptRegistrationTransfer(IdentityId id) external override {
        address proposed = proposedRegistrants[id];
        if (msg.sender != proposed) revert Unauthorized();
        registrations[id].registrant = proposed;
        delete proposedRegistrants[id];
    }

    function grantIdentity(IdentityId id, address to, uint64 expiry)
        external
        override
        onlyPermitter(id)
    {
        permits[to][id] = Permit({expiry: expiry});
        permittedAccounts[id].add(to);
        emit IdentityGranted(id, to);
    }

    function revokeIdentity(IdentityId id, address from) external override onlyPermitter(id) {
        delete permits[from][id];
        permittedAccounts[id].remove(from);
        emit IdentityRevoked(id, from);
    }

    function getPermitter(IdentityId id) external view override returns (IPermitter) {
        return permitters[id];
    }

    function readPermit(address holder, IdentityId id)
        public
        view
        override
        returns (Permit memory)
    {
        return permits[holder][id];
    }

    function getRegistrant(IdentityId id)
        external
        view
        override
        returns (address current, address proposed)
    {
        current = registrations[id].registrant;
        proposed = proposedRegistrants[id];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IIdentityRegistry).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _requireIsPermitter(address permitter) internal view returns (IPermitter) {
        if (!ERC165Checker.supportsInterface(permitter, type(IPermitter).interfaceId)) {
            revert InterfaceUnsupported();
        }
        return IPermitter(permitter);
    }

    function _whenIdentityCreated(IdentityId id, bytes calldata pers) internal virtual {}

    function _whenIdentityDestroyed(IdentityId id) internal virtual {}
}