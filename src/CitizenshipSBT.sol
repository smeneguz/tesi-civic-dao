// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC5192} from "./interfaces/IERC5192.sol";

/// @title CitizenshipSBT
/// @notice Token di cittadinanza soulbound (ERC-5192) della CivicDAO.
///         Ricostruzione fedele del contratto descritto nella tesi (sez. 5.4):
///         traduce l'autorizzazione firmata dal Comune in un token non
///         trasferibile, non replicabile e verificabile on-chain.
/// @dev    Soddisfa RF-01 (conio previa verifica identità/residenza tramite
///         firma dell'ente) e RF-02 (un solo token per residente, non
///         trasferibile). La cittadinanza, una volta coniata, è definitiva:
///         il contratto non prevede alcun meccanismo di revoca.
contract CitizenshipSBT is ERC721, AccessControl, EIP712, IERC5192 {
    // --- Ruoli (sez. 5.4.1) ---
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    // --- EIP-712: tipo del messaggio firmato dal Comune (passo 10 del flusso) ---
    bytes32 public constant MINT_AUTH_TYPEHASH =
        keccak256("MintAuth(address addressTo,bytes32 nullifier,uint256 deadline)");

    uint256 private _nextId = 1;

    /// @notice Cittadini attualmente titolari del token (mint - burn).
    /// @dev    ERC721 "liscio" non espone un contatore di supply (a differenza di
    ///         ERC721Enumerable, che però tiene array O(n) pensati per
    ///         l'enumerazione, superflui qui e più costosi in gas ad ogni mint).
    ///         Un contatore incrementato al mint è la scelta più economica per
    ///         esporre `totalSupply()` a chi (es. ParticipatoryBudget) lo usa
    ///         come elettorato per il quorum. Decrementato al burn: il contratto
    ///         non definisce oggi alcuna funzione di burn/revoca (vedi sopra),
    ///         ma il contatore è pronto a restare corretto se in futuro se ne
    ///         aggiungesse una.
    uint256 private _totalSupply;

    /// @notice nullifier già consumati (impedisce il replay dell'autorizzazione).
    ///         Non essendoci revoca, un nullifier usato resta consumato per sempre.
    mapping(bytes32 => bool) public nullifierUsed;

    // --- Errori (i 4 controlli on-chain, sez. 5.4.2) ---
    error DeadlineExpired();
    error InvalidIssuerSignature();
    error NullifierAlreadyUsed();
    error AlreadyCitizen();
    error NonTransferable();
    error TokenDoesNotExist();

    event CitizenshipMinted(address indexed to, uint256 indexed tokenId, bytes32 indexed nullifier);

    constructor(address admin, address issuer)
        ERC721("CitizenshipSBT", "CIT")
        EIP712("CitizenshipSBT", "1")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, issuer);
    }

    /// @notice Punto di ingresso per l'emissione del token (sez. 5.4.2).
    ///         Chiunque può inviare la transazione (compatibile con relayer
    ///         gasless, RNF-07): la legittimità dipende dalla firma, non dal
    ///         mittente.
    function mintWithAuth(
        address addressTo,
        bytes32 nullifier,
        uint256 deadline,
        bytes calldata sig
    ) external {
        // (a) Validità temporale
        if (block.timestamp > deadline) revert DeadlineExpired();

        // (b) Autenticità e autorizzazione della firma (EIP-712 + ruolo ISSUER)
        bytes32 digest = hashMintAuth(addressTo, nullifier, deadline);
        address signer = ECDSA.recover(digest, sig);
        if (!hasRole(ISSUER_ROLE, signer)) revert InvalidIssuerSignature();

        // (c) Non riutilizzo del nullifier
        if (nullifierUsed[nullifier]) revert NullifierAlreadyUsed();

        // (d) Unicità dell'indirizzo (una persona, un voto)
        if (balanceOf(addressTo) != 0) revert AlreadyCitizen();

        nullifierUsed[nullifier] = true;
        uint256 tokenId = _nextId++;
        _mint(addressTo, tokenId);

        emit Locked(tokenId); // evento ERC-5192: token permanentemente soulbound
        emit CitizenshipMinted(addressTo, tokenId, nullifier);
    }

    /// @inheritdoc IERC5192
    function locked(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        return true; // tutti i token sono permanentemente non trasferibili
    }

    /// @notice Digest EIP-712 dell'autorizzazione di conio.
    /// @dev    Esposto come helper: il Comune firma questo
    ///         digest off-chain. Lega implicitamente la firma a questo
    ///         contratto e a questa chain (domain separator).
    function hashMintAuth(address addressTo, bytes32 nullifier, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(MINT_AUTH_TYPEHASH, addressTo, nullifier, deadline))
        );
    }

    // --- Soulbound (RF-02): consentito solo il conio (from==0); nessuna
    //     funzione di burn è definita in questo contratto, quindi in pratica
    //     un token, una volta coniato, non può più essere né trasferito né
    //     distrutto da nessuno. ---
    // @dev _update is ERC721's single choke point for every mint (from==0),
    //      burn (to==0) and transfer, so maintaining _totalSupply here keeps
    //      it correct automatically even if a burn function were added later,
    //      with no separate bookkeeping to remember at each call site.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        if (from == address(0)) _totalSupply++; // mint
        else if (to == address(0)) _totalSupply--; // burn (no such path exists today)
        return super._update(to, tokenId, auth);
    }

    /// @notice Numero di cittadini attualmente titolari del token (mint - burn).
    /// @dev    Usato da ParticipatoryBudget come snapshot dell'elettorato per il
    ///         calcolo del quorum.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }
}
