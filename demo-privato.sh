#!/usr/bin/env bash
#
# demo-privato.sh
#
# Demo narrata, passo per passo, del flusso privato della CivicDAO --
# CivicProject, la macchina a stati che governa il ciclo di vita di un
# progetto civico interamente gestito dalla comunita' (tesi, sez. 4.4.2,
# Fig. 4.5) -- eseguita con transazioni VERE contro un nodo Anvil locale che
# questo script avvia e spegne da solo.
#
# Cosa dimostra, con transazioni reali (non con i cheatcode di Forge):
#   1. Gli account Anvil di default: account #0 = Comune, confinato al
#      proprio ruolo di certificatore d'identita' (admin+ISSUER_ROLE SOLO su
#      CitizenshipSBT); account #1-5 = cittadini onboardati con la vera firma
#      EIP-712 del Comune; account #6 = giurata; account #7 = "Bar del Corso"
#      (impresa che aderisce alla DAO iscrivendosi con MerchantMembership);
#      account #8 = l'ETS (Ente del Terzo Settore), l'ente giuridico DELLA
#      DAO stessa -- admin+issuer di tutta l'economia interna
#      (MerchantMembership, CommunityCredit, ProofOfParticipation,
#      Reputation) e chi concede a CivicProject i ruoli MINTER_ROLE/
#      SCORER_ROLE su di essa. Comune ed ETS sono deliberatamente due
#      soggetti distinti: il Comune certifica CHI entra nella comunita',
#      l'ETS amministra l'economia CHE la comunita' usa al proprio interno.
#   2. Un cittadino propone un progetto con team, allocazione di community
#      credit, un budget in euro DICHIARATO (informativo per il voto, mai
#      pagato ne' verificato on-chain -- il rimborso reale segue le ricevute
#      nell'evidenza IPFS, non questa cifra) e le due finestre temporali (qui
#      lasciate ai default di contratto: 7 giorni di verifica, 30 di
#      esecuzione).
#   3. Ogni membro del team da' consenso ON-CHAIN; solo quando TUTTI hanno
#      consentito il progetto passa in votazione (si vota solo su un team
#      reale e gia' impegnato).
#   4. La comunita' vota (un cittadino, un voto): il progetto raggiunge
#      Funded -- un FLAG che autorizza il team a partire, nessun valore si
#      muove on-chain (il budget in euro resta interamente off-chain).
#   5. Il team carica le prove (un ipfsHash fittizio) -> Submitted, apre la
#      finestra di verifica ottimistica.
#   6. Tre progetti, tre esiti diversi:
#        A) percorso ottimistico: nessuna contestazione entro 7 giorni ->
#           Confirmed. Si narrano i conii (community credit + proof-of-
#           participation + reputazione) verso ciascun performer e l'evento
#           di rimborso ReimbursementDue.
#        B) contestazione con verdetto FAVOREVOLE: un cittadino contesta ->
#           Challenged -> la giurata conferma -> Confirmed, stessi conii.
#        C) contestazione con verdetto SFAVOREVOLE: un cittadino contesta ->
#           Challenged -> la giurata respinge -> Rejected: NULLA viene
#           coniato (lo si verifica leggendo i contatori dei mock on-chain).
#   7. Time-jump: contro un nodo Anvil VIVO, vm.warp (cheatcode di Forge) non
#      ha alcun effetto. Questo script usa le RPC proprie di Anvil,
#      evm_increaseTime + evm_mine (via `cast rpc`), deterministiche e
#      istantanee. Usa i default REALI di contratto (7gg/finestra di voto
#      3gg): non servono finestre accorciate perche' il time-jump e' istantaneo
#      indipendentemente dalla durata.
#   8. Il CIRCUITO CHIUSO del community credit per intero (tesi sez. 4.5.4),
#      tutti e tre gli stadi: 1) conio verso il performer (visto al punto 6);
#      2) spesa: Bob spende meta' del suo credito presso "Bar del Corso", che
#      nel frattempo si e' iscritta alla DAO (MerchantMembership); contro-prova
#      che un cittadino NON puo' mai ricevere credito da un altro cittadino
#      (revert NotAuthorizedRecipient); 3) redeem: l'impresa restituisce alla
#      DAO il credito accumulato, che lo BRUCIA (supply totale diminuisce),
#      emettendo Redeemed -- in cambio l'impresa riceve visibilita'/
#      sponsorizzazione OFF-CHAIN, esattamente come il rimborso in euro di
#      CivicProject: la catena registra il fatto, il servizio reale avviene
#      fuori. Contro-prova anche qui: un cittadino non puo' fare redeem.
#   9. Riepilogo finale dei tre progetti e del circuito chiuso.
#
# Nota sui cittadini: sono onboardati con il vero flusso EIP-712
# (CitizenshipSBT.mintWithAuth, firma del Comune, nullifier = keccak(codice
# fiscale || segreto del Comune) -- stesso schema anti-Sybil-per-persona di
# demo-participatory-budget.sh), NON con una scorciatoia da deployer. Questa
# demo resta comunque incentrata sul flusso privato di CivicProject, che
# dipende da CitizenshipSBT solo in lettura tramite balanceOf.
#
# Delle quattro interfacce di frontiera (ICommunityCredit, IProofOfParticipation,
# IReputation, IJury), le prime tre sono soddisfatte dalle implementazioni
# REALI (src/CommunityCredit.sol, src/ProofOfParticipation.sol,
# src/Reputation.sol -- amministrate dall'ETS, non dal Comune, si veda il
# punto 1 sopra -- CommunityCredit dipende a sua volta da una vera
# MerchantMembership, la cui spesa/redeem presso un esercente e' proprio il
# circuito chiuso dimostrato al punto 8 sopra). L'UNICO mock
# rimasto e' MockJury (test/mocks/CivicProjectMocks.sol): l'unica delle
# quattro interfacce senza ancora un'implementazione reale nel progetto.
# CivicProject stesso non e' mai stato ricompilato o toccato: e' lo stesso
# identico contratto che dipende solo dalle interfacce, mai da un'
# implementazione concreta -- e' lo script a deployare contratti diversi
# dietro le stesse interfacce.
#
# Uso: ./demo-privato.sh   (un solo comando; avvia e spegne Anvil da solo)
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Narrazione da terminale
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'; RESET=$'\033[0m'
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; MAGENTA=$'\033[35m'; BLUE=$'\033[34m'

# Tutta la narrazione va su stderr: molte funzioni sotto vengono chiamate come
# `x=$(funzione ...)` per catturare un vero valore di ritorno (un indirizzo,
# un projectId, un contatore) su stdout. Se la narrazione andasse su stdout
# finirebbe inglobata nel valore catturato invece di comparire a schermo.
# Pausa prima di ogni intestazione blu, cosi' chi presenta puo' avanzare una
# fase alla volta premendo Invio (invece che vedersi scorrere tutto il demo
# in automatico). Legge dal terminale di controllo (/dev/tty) invece che dal
# semplice stdin dello script, cosi' funziona anche se lo stdin dello script
# e' rediretto. Se non c'e' proprio nessun terminale disponibile (es. in CI
# con output rediretto su file), salta la pausa invece di restare bloccato.
pause_prossima_fase() {
    if [ -t 0 ] || [ -r /dev/tty ]; then
        printf "\n  ${YELLOW}...${RESET} Premi Invio per continuare" >&2
        read -r _ < /dev/tty 2>/dev/null || read -r _
    fi
}

section() { pause_prossima_fase; printf "\n${BOLD}${CYAN}== %s ==${RESET}\n" "$1" >&2; }
info()    { printf "  %s\n" "$1" >&2; }
ok()      { printf "  ${GREEN}OK${RESET}  %s\n" "$1" >&2; }
warn()    { printf "  ${YELLOW}!${RESET}   %s\n" "$1" >&2; }
mint()    { printf "  ${MAGENTA}conio${RESET}  %s\n" "$1" >&2; }
vote()    { printf "  ${BLUE}voto${RESET}   %s\n" "$1" >&2; }
juror()   { printf "  ${YELLOW}giuria${RESET} %s\n" "$1" >&2; }

die() {
    printf "\n${RED}${BOLD}ERRORE IMPREVISTO${RESET}: %b\n" "$1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Ciclo di vita di Anvil (un solo comando: avvio in background, arresto in uscita)
# ---------------------------------------------------------------------------
RPC="http://127.0.0.1:8545"
ANVIL_LOG="$(mktemp -t anvil-privato-demo-XXXXXX.log)"
ANVIL_PID=""

cleanup() {
    if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        section "Arresto"
        info "Fermo il nodo Anvil (pid $ANVIL_PID)..."
        kill "$ANVIL_PID" 2>/dev/null
        wait "$ANVIL_PID" 2>/dev/null
        ok "Anvil fermato. Log completo: $ANVIL_LOG"
    fi
}
trap cleanup EXIT INT TERM

section "Avvio del nodo locale"
info "Lancio Anvil su $RPC (log completo: $ANVIL_LOG)..."
anvil --port 8545 >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!

READY=0
for _ in $(seq 1 30); do
    if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then READY=1; break; fi
    sleep 0.3
done
[ "$READY" = "1" ] || die "Anvil non risponde su $RPC dopo 9s. Controlla $ANVIL_LOG."
ok "Anvil pronto (chain id $(cast chain-id --rpc-url "$RPC"))."

# ---------------------------------------------------------------------------
# Account Anvil di default (mnemonic pubblico "test test ... junk").
# Pubblici, fissi, pensati solo per lo sviluppo locale -- da non riusare mai
# fuori da un nodo locale come questo.
# ---------------------------------------------------------------------------
ADDR_COMUNE=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK_COMUNE=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

ADDR_ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PK_ALICE=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

ADDR_BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
PK_BOB=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

ADDR_CAROL=0x90F79bf6EB2c4f870365E785982E1f101E93b906
PK_CAROL=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6

ADDR_DAVE=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
PK_DAVE=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a

ADDR_ELENA=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
PK_ELENA=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba

ADDR_GIULIA=0x976EA74026E726554dB657fA54763abd0C3a0aa9
PK_GIULIA=0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e

ADDR_MERCHANT=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955 # account #7: "Bar del Corso"
PK_MERCHANT=0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356

# account #8: l'ETS (Ente del Terzo Settore), l'ente giuridico DELLA DAO
# stessa -- distinto dal Comune. Amministra l'economia interna della DAO
# (MerchantMembership, CommunityCredit, ProofOfParticipation, Reputation):
# il Comune resta invece confinato al proprio ruolo di certificatore
# d'identita' (CitizenshipSBT). Nessuna riga di Solidity cambia per questo:
# i costruttori di quei contratti gia' accettano un admin/issuer qualsiasi,
# prima passavamo (per semplicita') sempre lo stesso indirizzo del Comune.
ADDR_ETS=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f
PK_ETS=0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97

# ---------------------------------------------------------------------------
# Codici fiscali fittizi (dati di demo, nessuna persona reale) e segreto del
# Comune per il nullifier di onboarding -- stesso schema di
# demo-participatory-budget.sh: nullifier = keccak(codiceFiscale || segreto),
# cosi' l'anti-Sybil e' sulla PERSONA, non sul wallet. Vedi quello script per
# la spiegazione completa del perche' serve un segreto.
# ---------------------------------------------------------------------------
MUNICIPALITY_SECRET="comune-segreto-demo-non-usare-in-produzione"

CF_ALICE="LCAALC85A41H501K"
CF_BOB="BOBRRT82B15H501J"
CF_CAROL="CRLCRL90C58H501Y"
CF_DAVE="DVAADV79D22H501B"
CF_ELENA="LNEELN95E60H501P"

section "Attori della demo (account Anvil di default)"
info "Account #0  Comune (ISSUER_ROLE su CitizenshipSBT: identita')          = $ADDR_COMUNE"
info "Account #1  Alice  (cittadina)                                        = $ADDR_ALICE"
info "Account #2  Bob    (cittadino)                                        = $ADDR_BOB"
info "Account #3  Carol  (cittadina)                                        = $ADDR_CAROL"
info "Account #4  Dave   (cittadino)                                        = $ADDR_DAVE"
info "Account #5  Elena  (cittadina)                                        = $ADDR_ELENA"
info "Account #6  Giulia (giurata, IJury.isJuror)                           = $ADDR_GIULIA"
info "Account #7  Bar del Corso (impresa aderente alla DAO, non ancora iscritta) = $ADDR_MERCHANT"
info "Account #8  ETS (admin+issuer dell'economia interna della DAO)        = $ADDR_ETS"

# ---------------------------------------------------------------------------
# Deploy: CivicProject + le implementazioni REALI di CitizenshipSBT,
# MerchantMembership (prerequisito di CommunityCredit), CommunityCredit,
# ProofOfParticipation, Reputation -- e MockJury, l'unica interfaccia di
# frontiera ancora priva di un'implementazione reale nel progetto.
# CivicProject non dipende MAI dalle implementazioni concrete dell'economia:
# solo dalle 4 interfacce di frontiera, e da CitizenshipSBT solo in lettura
# (balanceOf/totalSupply).
# ---------------------------------------------------------------------------
section "Deploy dei contratti"

# NOTA: chi paga il gas del deploy (--private-key qui sotto) e chi diventa
# admin/issuer sono due cose indipendenti in Ethereum -- solo gli argomenti
# del costruttore contano per i ruoli AccessControl. Il Comune paga il gas di
# ogni deploy per semplicita' dello script, ma questo non gli da' alcun
# potere sui contratti la cui amministrazione passiamo esplicitamente
# all'ETS qui sotto (MerchantMembership/CommunityCredit/ProofOfParticipation/
# Reputation).
deploy() {
    local label="$1" contract="$2"; shift 2
    local json addr
    json=$(forge create "$contract" --rpc-url "$RPC" --private-key "$PK_COMUNE" --broadcast --json "$@" 2>&1) \
        || die "Deploy di $label fallito:\n$json"
    addr=$(echo "$json" | grep -oE '"deployedTo": *"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+')
    [ -n "$addr" ] || die "Non riesco a leggere l'indirizzo di $label da:\n$json"
    echo "$addr"
}

SBT=$(deploy "CitizenshipSBT" "src/CitizenshipSBT.sol:CitizenshipSBT" \
    --constructor-args "$ADDR_COMUNE" "$ADDR_COMUNE")
MERCHANT=$(deploy "MerchantMembership" "src/MerchantMembership.sol:MerchantMembership" \
    --constructor-args "$ADDR_ETS" "$ADDR_ETS")
CREDIT=$(deploy "CommunityCredit" "src/CommunityCredit.sol:CommunityCredit" \
    --constructor-args "$ADDR_ETS" "$MERCHANT")
POP=$(deploy "ProofOfParticipation" "src/ProofOfParticipation.sol:ProofOfParticipation" \
    --constructor-args "$ADDR_ETS")
REP=$(deploy "Reputation" "src/Reputation.sol:Reputation" \
    --constructor-args "$ADDR_ETS" "$SBT" 0)
JURY=$(deploy "MockJury" "test/mocks/CivicProjectMocks.sol:MockJury")
CP=$(deploy "CivicProject" "src/CivicProject.sol:CivicProject" \
    --constructor-args "$SBT" "$CREDIT" "$POP" "$REP" "$JURY")

ok "CitizenshipSBT:       $SBT"
ok "MerchantMembership:   $MERCHANT"
ok "CommunityCredit:      $CREDIT"
ok "ProofOfParticipation: $POP"
ok "Reputation:           $REP  (decayRatePerDay = 0, nessun decadimento in questa demo)"
ok "MockJury:             $JURY  (unico mock: nessuna implementazione reale di IJury nel progetto)"
ok "CivicProject:         $CP"

info ""


# A differenza dei mock (senza alcun controllo d'accesso), le implementazioni
# reali proteggono le proprie funzioni di scrittura con un ruolo: bisogna
# concederlo esplicitamente a CivicProject, altrimenti ogni conio a fine
# progetto andrebbe in revert. Letto on-chain (nessun ruolo cablato nello
# script), coerente con come gia' si leggono le altre costanti di contratto.
# Firma l'ETS, non il Comune: e' l'ETS il DEFAULT_ADMIN_ROLE su questi tre
# contratti (vedi il deploy sopra), quindi solo lui puo' concedere i ruoli.
section "Concessione dei ruoli a CivicProject sui contratti reali"

grant_role() {
    local label="$1" contract="$2" role_fn="$3" grantee="$4"
    local role out
    role=$(cast call "$contract" "$role_fn()(bytes32)" --rpc-url "$RPC")
    out=$(cast send "$contract" "grantRole(bytes32,address)" "$role" "$grantee" \
        --private-key "$PK_ETS" --rpc-url "$RPC" 2>&1) \
        || die "grantRole($label) a CivicProject fallita:\n$out"
    ok "$label concesso a CivicProject."
}

grant_role "CommunityCredit.MINTER_ROLE"      "$CREDIT" "MINTER_ROLE" "$CP"
grant_role "ProofOfParticipation.MINTER_ROLE" "$POP"    "MINTER_ROLE" "$CP"
grant_role "Reputation.SCORER_ROLE"           "$REP"    "SCORER_ROLE" "$CP"

# ---------------------------------------------------------------------------
# Cittadinanza: flusso EIP-712 REALE (mintWithAuth), non una scorciatoia da
# deployer. Il nullifier lega la cittadinanza alla PERSONA (codice fiscale +
# segreto del Comune), non al wallet -- stesso schema e stessa funzione
# onboard() di demo-participatory-budget.sh.
# ---------------------------------------------------------------------------
section "Cittadinanza (flusso EIP-712 reale: mintWithAuth)"

onboard() {
    local addr="$1" pk="$2" cf="$3"
    local nullifier deadline digest sig out
    nullifier=$(cast keccak "$cf:$MUNICIPALITY_SECRET")
    deadline=$(( $(date +%s) + 3600 ))
    digest=$(cast call "$SBT" "hashMintAuth(address,bytes32,uint256)(bytes32)" \
        "$addr" "$nullifier" "$deadline" --rpc-url "$RPC") \
        || die "hashMintAuth() on-chain fallita per $addr"
    sig=$(cast wallet sign --no-hash --private-key "$PK_COMUNE" "$digest")
    out=$(cast send "$SBT" "mintWithAuth(address,bytes32,uint256,bytes)" \
        "$addr" "$nullifier" "$deadline" "$sig" \
        --private-key "$pk" --rpc-url "$RPC" 2>&1) \
        || die "mintWithAuth doveva riuscire per $addr ma e' fallita:\n$out"
}

onboard "$ADDR_ALICE" "$PK_ALICE" "$CF_ALICE"
onboard "$ADDR_BOB"   "$PK_BOB"   "$CF_BOB"
onboard "$ADDR_CAROL" "$PK_CAROL" "$CF_CAROL"
onboard "$ADDR_DAVE"  "$PK_DAVE"  "$CF_DAVE"
onboard "$ADDR_ELENA" "$PK_ELENA" "$CF_ELENA"
ok "5 cittadini onboardati con firma EIP-712 reale del Comune: Alice, Bob, Carol, Dave, Elena."

info "Giulia (account #6) e' giurata (IJury.isJuror)"
OUT=$(cast send "$JURY" "setJuror(address,bool)" "$ADDR_GIULIA" true --private-key "$PK_COMUNE" --rpc-url "$RPC" 2>&1) \
    || die "Nomina di Giulia a giurata fallita:\n$OUT"
ok "Giulia nominata giurata."

# ---------------------------------------------------------------------------
# Costanti di contratto lette on-chain (nessun valore cablato nello script).
# ---------------------------------------------------------------------------
VOTING_DURATION=$(cast call "$CP" "VOTING_DURATION()(uint64)" --rpc-url "$RPC" | grep -oE '^[0-9]+')
VERIFICATION_WINDOW=$(cast call "$CP" "DEFAULT_VERIFICATION_WINDOW()(uint64)" --rpc-url "$RPC" | grep -oE '^[0-9]+')
EXECUTION_WINDOW=$(cast call "$CP" "DEFAULT_EXECUTION_WINDOW()(uint64)" --rpc-url "$RPC" | grep -oE '^[0-9]+')
REPUTATION_INCREMENT=$(cast call "$CP" "REPUTATION_INCREMENT()(uint256)" --rpc-url "$RPC" | grep -oE '^[0-9]+')
QUORUM_BPS=$(cast call "$CP" "QUORUM_BPS()(uint256)" --rpc-url "$RPC" | grep -oE '^[0-9]+')
BPS_DENOMINATOR=$(cast call "$CP" "BPS_DENOMINATOR()(uint256)" --rpc-url "$RPC" | grep -oE '^[0-9]+')

info ""
info "Parametri di contratto (letti on-chain): finestra di voto ${VOTING_DURATION}s"
info "($((VOTING_DURATION/86400))gg), finestra di verifica default ${VERIFICATION_WINDOW}s ($((VERIFICATION_WINDOW/86400))gg),"
info "finestra di esecuzione default ${EXECUTION_WINDOW}s ($((EXECUTION_WINDOW/86400))gg), quorum"
info "$((QUORUM_BPS * 100 / BPS_DENOMINATOR))% dell'elettorato (snapshot preso all'apertura del voto, come nel"
info "flusso pubblico), incremento reputazione $REPUTATION_INCREMENT per performer confermato."

# ---------------------------------------------------------------------------
# Helper riutilizzabili per le tre storie di progetto.
# ---------------------------------------------------------------------------

# Avanza l'orologio della chain di N secondi. vm.warp NON ha effetto contro un
# nodo Anvil vivo: solo le RPC proprie di Anvil (evm_increaseTime + evm_mine,
# via `cast rpc`) muovono davvero il tempo on-chain. Deterministico e istantaneo.
advance_time() {
    local seconds="$1"
    cast rpc evm_increaseTime "$seconds" --rpc-url "$RPC" >/dev/null || die "evm_increaseTime fallito"
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null || die "evm_mine fallito"
}

status_name() {
    case "$1" in
        0) echo "Proposed" ;;
        1) echo "Voting" ;;
        2) echo "Funded" ;;
        3) echo "Archived" ;;
        4) echo "Submitted" ;;
        5) echo "Challenged" ;;
        6) echo "Confirmed" ;;
        7) echo "Rejected" ;;
        8) echo "Expired" ;;
        *) echo "sconosciuto($1)" ;;
    esac
}

# Legge lo status corrente di un progetto tramite la view di comodo
# getStatus(uint256) (un solo uint8, niente da decodificare a mano).
get_status() {
    cast call "$CP" "getStatus(uint256)(uint8)" "$1" --rpc-url "$RPC" | grep -oE '^[0-9]+'
}

# I contratti REALI non hanno un callCount() come i mock: si verificano i
# conii leggendo i saldi veri di ciascun performer (ERC20/ERC721 balanceOf,
# punteggio Reputation), prima e dopo ogni conferma/rigetto.
credit_balance() { cast call "$CREDIT" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | grep -oE '^[0-9]+'; }
pop_balance()    { cast call "$POP" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | grep -oE '^[0-9]+'; }
reputation_of()  { cast call "$REP" "reputationOf(address)(uint256)" "$1" --rpc-url "$RPC" | grep -oE '^[0-9]+'; }

propose_project() {
    local proposer_pk="$1" description="$2" team_json="$3" allocation="$4" budget_euro="$5"
    local out id
    out=$(cast send "$CP" "propose(string,address[],uint256,uint256,uint64,uint64)" \
        "$description" "$team_json" "$allocation" "$budget_euro" 0 0 \
        --private-key "$proposer_pk" --rpc-url "$RPC" 2>&1) \
        || die "propose(\"$description\") fallita:\n$out"
    id=$(cast call "$CP" "projectCount()(uint256)" --rpc-url "$RPC" | grep -oE '^[0-9]+')
    echo "$((id - 1))"
}

give_consent() {
    local id="$1" name="$2" pk="$3"
    local out
    out=$(cast send "$CP" "consentToTeam(uint256)" "$id" --private-key "$pk" --rpc-url "$RPC" 2>&1) \
        || die "$name: consentToTeam(#$id) fallita:\n$out"
    ok "$name ha dato consenso on-chain al team del progetto #$id."
}

cast_yes_vote() {
    local id="$1" name="$2" pk="$3"
    local out
    out=$(cast send "$CP" "vote(uint256,bool)" "$id" true --private-key "$pk" --rpc-url "$RPC" 2>&1) \
        || die "$name: vote(#$id) fallito:\n$out"
    vote "$name vota SI' sul progetto #$id."
}

close_and_check_funded() {
    local id="$1"
    advance_time $((VOTING_DURATION + 5))
    local out
    out=$(cast send "$CP" "closeVoting(uint256)" "$id" --private-key "$PK_COMUNE" --rpc-url "$RPC" 2>&1) \
        || die "closeVoting(#$id) fallita:\n$out"
    local st; st=$(get_status "$id")
    [ "$st" = "2" ] || die "Il progetto #$id doveva raggiungere Funded, stato invece: $(status_name "$st")"
    ok "Progetto #$id -> Funded (quorum raggiunto, maggioranza favorevole). "
}

submit_evidence() {
    local id="$1" submitter_pk="$2" ipfs="$3" performers_json="$4"
    local out
    out=$(cast send "$CP" "submitEvidence(uint256,string,address[])" \
        "$id" "$ipfs" "$performers_json" --private-key "$submitter_pk" --rpc-url "$RPC" 2>&1) \
        || die "submitEvidence(#$id) fallita:\n$out"
    ok "Progetto #$id -> Submitted. Prova caricata: $ipfs"
}

# ===========================================================================
section "PROGETTO A -- \"Pulizia del parco\" (percorso ottimistico)"
# ===========================================================================
info "Alice propone; team = Bob + Carol; allocazione = 200 community credit;"
info "budget dichiarato = 800 euro (solo informativo per il voto, mai pagato"
info "on-chain: il rimborso reale seguira' le ricevute nell'evidenza IPFS)."

TEAM_A="[$ADDR_BOB,$ADDR_CAROL]"
PID_A=$(propose_project "$PK_ALICE" "Pulizia del parco" "$TEAM_A" 200 800)
ok "Progetto #$PID_A proposto da Alice. Stato: Proposed."

info "Consenso on-chain del team (obbligatorio PRIMA del voto):"
give_consent "$PID_A" "Bob" "$PK_BOB"
give_consent "$PID_A" "Carol" "$PK_CAROL"
st=$(get_status "$PID_A")
ok "Ultimo consenso ricevuto -> transizione automatica a Voting (stato: $(status_name "$st"))."

info "Votazione (un cittadino, un voto):"
cast_yes_vote "$PID_A" "Alice" "$PK_ALICE"
cast_yes_vote "$PID_A" "Dave" "$PK_DAVE"
cast_yes_vote "$PID_A" "Elena" "$PK_ELENA"
close_and_check_funded "$PID_A"

info "Il team carica le prove: solo Bob e Carol hanno davvero partecipato."
PERFORMERS_A="[$ADDR_BOB,$ADDR_CAROL]"
submit_evidence "$PID_A" "$PK_BOB" "ipfs://bafybei-demo-parco-pulito-0001" "$PERFORMERS_A"

info "Percorso OTTIMISTICO: nessuno contesta entro la finestra di verifica"
info "(${VERIFICATION_WINDOW}s = $((VERIFICATION_WINDOW/86400)) giorni). Avanzo il tempo e chiunque puo' confermare."
advance_time $((VERIFICATION_WINDOW + 5))

CREDIT_BEFORE_A=$(( $(credit_balance "$ADDR_BOB") + $(credit_balance "$ADDR_CAROL") ))
POP_BEFORE_A=$(( $(pop_balance "$ADDR_BOB") + $(pop_balance "$ADDR_CAROL") ))
REP_BEFORE_A=$(( $(reputation_of "$ADDR_BOB") + $(reputation_of "$ADDR_CAROL") ))
OUT=$(cast send "$CP" "confirmOptimistic(uint256)" "$PID_A" --private-key "$PK_DAVE" --rpc-url "$RPC" 2>&1) \
    || die "confirmOptimistic(#$PID_A) fallita:\n$OUT"
st=$(get_status "$PID_A")
[ "$st" = "6" ] || die "Il progetto #$PID_A doveva raggiungere Confirmed, stato invece: $(status_name "$st")"
ok "Progetto #$PID_A -> Confirmed (confermato da Dave, un cittadino qualunque: la funzione e' permissionless)."

info "Effetti della conferma (per ciascun performer, chiamata singola non batch):"
QUOTA_A=$((200 / 2))
for i in 0 1; do
    PERFORMER=$([ "$i" = "0" ] && echo "$ADDR_BOB (Bob)" || echo "$ADDR_CAROL (Carol)")
    mint "$PERFORMER -> communityCredit.mint(_, $QUOTA_A)  [200 / 2 performer]"
    mint "$PERFORMER -> proofOfParticipation.mint(_, projectId=$PID_A)"
    mint "$PERFORMER -> reputation.increase(_, $REPUTATION_INCREMENT)"
done
CREDIT_AFTER_A=$(( $(credit_balance "$ADDR_BOB") + $(credit_balance "$ADDR_CAROL") ))
POP_AFTER_A=$(( $(pop_balance "$ADDR_BOB") + $(pop_balance "$ADDR_CAROL") ))
REP_AFTER_A=$(( $(reputation_of "$ADDR_BOB") + $(reputation_of "$ADDR_CAROL") ))
ok "Verificato on-chain (saldi reali di Bob+Carol): community credit +$((CREDIT_AFTER_A - CREDIT_BEFORE_A)) (atteso $((QUOTA_A * 2))), badge PoP +$((POP_AFTER_A - POP_BEFORE_A)) (atteso 2), reputazione +$((REP_AFTER_A - REP_BEFORE_A)) (atteso $((REPUTATION_INCREMENT * 2)))."
ok "Evento ReimbursementDue(#$PID_A, proposer=Alice, performerCount=2) emesso: base contabile per il rimborso in euro off-chain."

# ===========================================================================
section "PROGETTO B -- \"Verniciatura delle panchine pubbliche\" (contestazione -> verdetto FAVOREVOLE)"
# ===========================================================================
info "Bob propone; team = Carol + Dave; allocazione = 300 community credit;"
info "budget dichiarato = 1200 euro."

TEAM_B="[$ADDR_CAROL,$ADDR_DAVE]"
PID_B=$(propose_project "$PK_BOB" "Verniciatura delle panchine pubbliche" "$TEAM_B" 300 1200)
ok "Progetto #$PID_B proposto da Bob."

give_consent "$PID_B" "Carol" "$PK_CAROL"
give_consent "$PID_B" "Dave" "$PK_DAVE"
ok "Team completo -> Voting."

cast_yes_vote "$PID_B" "Alice" "$PK_ALICE"
cast_yes_vote "$PID_B" "Elena" "$PK_ELENA"
cast_yes_vote "$PID_B" "Bob" "$PK_BOB"
close_and_check_funded "$PID_B"

PERFORMERS_B="[$ADDR_CAROL,$ADDR_DAVE]"
submit_evidence "$PID_B" "$PK_CAROL" "ipfs://bafybei-demo-panchine-0002" "$PERFORMERS_B"

info "Elena, cittadina, NON e' convinta dalla prova caricata: contesta entro la finestra."
OUT=$(cast send "$CP" "challenge(uint256)" "$PID_B" --private-key "$PK_ELENA" --rpc-url "$RPC" 2>&1) \
    || die "challenge(#$PID_B) fallita:\n$OUT"
st=$(get_status "$PID_B")
[ "$st" = "5" ] || die "Il progetto #$PID_B doveva raggiungere Challenged, stato invece: $(status_name "$st")"
ok "Progetto #$PID_B -> Challenged. La risoluzione passa alla giuria."

juror "Giulia (IJury.isJuror = true) esamina il caso ed emette verdetto: APPROVA la prova."
CREDIT_BEFORE_B=$(( $(credit_balance "$ADDR_CAROL") + $(credit_balance "$ADDR_DAVE") ))
POP_BEFORE_B=$(( $(pop_balance "$ADDR_CAROL") + $(pop_balance "$ADDR_DAVE") ))
REP_BEFORE_B=$(( $(reputation_of "$ADDR_CAROL") + $(reputation_of "$ADDR_DAVE") ))
OUT=$(cast send "$CP" "resolveChallenge(uint256,bool)" "$PID_B" true --private-key "$PK_GIULIA" --rpc-url "$RPC" 2>&1) \
    || die "resolveChallenge(#$PID_B, true) fallita:\n$OUT"
st=$(get_status "$PID_B")
[ "$st" = "6" ] || die "Il progetto #$PID_B doveva raggiungere Confirmed, stato invece: $(status_name "$st")"
ok "Progetto #$PID_B -> Confirmed (verdetto favorevole della giuria)."

QUOTA_B=$((300 / 2))
mint "Carol e Dave -> communityCredit.mint(_, $QUOTA_B) ciascuno  [300 / 2 performer]"
mint "Carol e Dave -> proofOfParticipation.mint(_, projectId=$PID_B) ciascuno"
mint "Carol e Dave -> reputation.increase(_, $REPUTATION_INCREMENT) ciascuno"
CREDIT_AFTER_B=$(( $(credit_balance "$ADDR_CAROL") + $(credit_balance "$ADDR_DAVE") ))
POP_AFTER_B=$(( $(pop_balance "$ADDR_CAROL") + $(pop_balance "$ADDR_DAVE") ))
REP_AFTER_B=$(( $(reputation_of "$ADDR_CAROL") + $(reputation_of "$ADDR_DAVE") ))
ok "Verificato on-chain (saldi reali di Carol+Dave): community credit +$((CREDIT_AFTER_B - CREDIT_BEFORE_B)) (atteso $((QUOTA_B * 2))), badge PoP +$((POP_AFTER_B - POP_BEFORE_B)) (atteso 2), reputazione +$((REP_AFTER_B - REP_BEFORE_B)) (atteso $((REPUTATION_INCREMENT * 2)))."
ok "Evento ReimbursementDue(#$PID_B, proposer=Bob, performerCount=2) emesso."

# ===========================================================================
section "PROGETTO C -- \"Restauro della fontana comunale\" (contestazione -> verdetto SFAVOREVOLE)"
# ===========================================================================
info "Carol propone; team = Alice + Dave; allocazione = 400 community credit;"
info "budget dichiarato = 3000 euro."

TEAM_C="[$ADDR_ALICE,$ADDR_DAVE]"
PID_C=$(propose_project "$PK_CAROL" "Restauro della fontana comunale" "$TEAM_C" 400 3000)
ok "Progetto #$PID_C proposto da Carol."

give_consent "$PID_C" "Alice" "$PK_ALICE"
give_consent "$PID_C" "Dave" "$PK_DAVE"
ok "Team completo -> Voting."

cast_yes_vote "$PID_C" "Bob" "$PK_BOB"
cast_yes_vote "$PID_C" "Elena" "$PK_ELENA"
cast_yes_vote "$PID_C" "Carol" "$PK_CAROL"
close_and_check_funded "$PID_C"

PERFORMERS_C="[$ADDR_ALICE,$ADDR_DAVE]"
submit_evidence "$PID_C" "$PK_ALICE" "ipfs://bafybei-demo-fontana-0003" "$PERFORMERS_C"

info "Elena contesta di nuovo: questa volta la giuria le dara' ragione."
OUT=$(cast send "$CP" "challenge(uint256)" "$PID_C" --private-key "$PK_ELENA" --rpc-url "$RPC" 2>&1) \
    || die "challenge(#$PID_C) fallita:\n$OUT"
ok "Progetto #$PID_C -> Challenged."

juror "Giulia esamina il caso ed emette verdetto: RESPINGE la prova."
CREDIT_BEFORE_C=$(( $(credit_balance "$ADDR_ALICE") + $(credit_balance "$ADDR_DAVE") ))
POP_BEFORE_C=$(( $(pop_balance "$ADDR_ALICE") + $(pop_balance "$ADDR_DAVE") ))
REP_BEFORE_C=$(( $(reputation_of "$ADDR_ALICE") + $(reputation_of "$ADDR_DAVE") ))
OUT=$(cast send "$CP" "resolveChallenge(uint256,bool)" "$PID_C" false --private-key "$PK_GIULIA" --rpc-url "$RPC" 2>&1) \
    || die "resolveChallenge(#$PID_C, false) fallita:\n$OUT"
st=$(get_status "$PID_C")
[ "$st" = "7" ] || die "Il progetto #$PID_C doveva raggiungere Rejected, stato invece: $(status_name "$st")"
ok "Progetto #$PID_C -> Rejected (verdetto sfavorevole della giuria)."

CREDIT_AFTER_C=$(( $(credit_balance "$ADDR_ALICE") + $(credit_balance "$ADDR_DAVE") ))
POP_AFTER_C=$(( $(pop_balance "$ADDR_ALICE") + $(pop_balance "$ADDR_DAVE") ))
REP_AFTER_C=$(( $(reputation_of "$ADDR_ALICE") + $(reputation_of "$ADDR_DAVE") ))
if [ "$CREDIT_AFTER_C" = "$CREDIT_BEFORE_C" ] && [ "$POP_AFTER_C" = "$POP_BEFORE_C" ] && [ "$REP_AFTER_C" = "$REP_BEFORE_C" ]; then
    ok "Verificato on-chain (saldi reali di Alice+Dave): NESSUNA variazione di community credit/badge PoP/reputazione."
    ok "Nessun evento ReimbursementDue: il rimborso in euro semplicemente non scatta (nessun evento emesso)."
else
    die "Su Rejected non doveva essere coniato nulla, ma i saldi reali sono cambiati!"
fi

# ---------------------------------------------------------------------------
# Impresa iscritta: paga la quota annuale ALL'ETS OFF-CHAIN; l'ETS -- ente
# giuridico della DAO stessa, distinto dal Comune, ISSUER_ROLE su
# MerchantMembership -- certifica il pagamento coniando l'NFT di iscrizione.
# Nessun euro si muove on-chain qui: solo la CERTIFICAZIONE di un pagamento
# gia' avvenuto altrove.
# ---------------------------------------------------------------------------
section "Impresa aderente alla DAO (MerchantMembership)"
info "\"Bar del Corso\" ($ADDR_MERCHANT) ha pagato la quota annuale all'ETS,"
info "off-chain. L'ETS certifica il pagamento coniando l'NFT di iscrizione:"
OUT=$(cast send "$MERCHANT" "mint(address)" "$ADDR_MERCHANT" --private-key "$PK_ETS" --rpc-url "$RPC" 2>&1) \
    || die "Iscrizione di Bar del Corso fallita:\n$OUT"
MERCHANT_ACTIVE=$(cast call "$MERCHANT" "isActiveMember(address)(bool)" "$ADDR_MERCHANT" --rpc-url "$RPC")
ok "MerchantMembership.mint(Bar del Corso) -- isActiveMember = $MERCHANT_ACTIVE."
info "Da qui in avanti, CommunityCredit accettera' trasferimenti VERSO questo indirizzo"

# ---------------------------------------------------------------------------
# Spesa: il credito coniato ai performer e' un vero ERC-20, spendibile pero'
# SOLO verso un'impresa con MerchantMembership attiva (tesi sez. 4.5.4).
# ---------------------------------------------------------------------------
section "Spesa del credito -- solo verso indirizzi autorizzati"
BOB_CREDIT=$(credit_balance "$ADDR_BOB")
SPEND=$((BOB_CREDIT / 2))
info "Bob spende meta' del suo credito ($BOB_CREDIT totale) da \"Bar del Corso\":"
MERCHANT_BEFORE_SPEND=$(credit_balance "$ADDR_MERCHANT")
OUT=$(cast send "$CREDIT" "transfer(address,uint256)" "$ADDR_MERCHANT" "$SPEND" --private-key "$PK_BOB" --rpc-url "$RPC" 2>&1) \
    || die "transfer verso l'impresa fallito:\n$OUT"
BOB_AFTER_SPEND=$(credit_balance "$ADDR_BOB")
MERCHANT_AFTER_SPEND=$(credit_balance "$ADDR_MERCHANT")
ok "Bob: community credit = $BOB_AFTER_SPEND (prima: $BOB_CREDIT, -$SPEND). Bar del Corso: community credit = $MERCHANT_AFTER_SPEND (prima: $MERCHANT_BEFORE_SPEND, +$SPEND)."

info ""
info "Contro-prova: Carol prova a mandare credito a Dave, un ALTRO cittadino"
info "(non un'impresa iscritta) -- ci si aspetta un revert:"
OUT=$(cast send "$CREDIT" "transfer(address,uint256)" "$ADDR_DAVE" 1 --private-key "$PK_CAROL" --rpc-url "$RPC" 2>&1)
if echo "$OUT" | grep -qi "NotAuthorizedRecipient"; then
    ok "Transfer verso un cittadino RIFIUTATO (NotAuthorizedRecipient): il credito non e' trasferibile tra cittadini."
else
    die "Il transfer verso un cittadino avrebbe dovuto fallire con NotAuthorizedRecipient, invece:\n$OUT"
fi

# ---------------------------------------------------------------------------
# Redeem: terzo e ultimo stadio del circuito chiuso (tesi sez. 4.5.4). L'impresa
# restituisce il credito accumulato alla DAO, che lo BRUCIA (supply totale
# diminuisce), in cambio di visibilita'/sponsorizzazione OFF-CHAIN -- on-chain
# resta solo l'evento Redeemed, esattamente come ReimbursementDue registra
# (senza muovere denaro) il rimborso in euro di CivicProject.
# ---------------------------------------------------------------------------
section "Redeem -- terzo e ultimo stadio del circuito chiuso"
SUPPLY_BEFORE_REDEEM=$(cast call "$CREDIT" "totalSupply()(uint256)" --rpc-url "$RPC")
info "\"Bar del Corso\" restituisce alla DAO tutto il credito accumulato ($MERCHANT_AFTER_SPEND):"
OUT=$(cast send "$CREDIT" "redeem(uint256)" "$MERCHANT_AFTER_SPEND" --private-key "$PK_MERCHANT" --rpc-url "$RPC" 2>&1) \
    || die "redeem fallito:\n$OUT"
MERCHANT_AFTER_REDEEM=$(credit_balance "$ADDR_MERCHANT")
SUPPLY_AFTER_REDEEM=$(cast call "$CREDIT" "totalSupply()(uint256)" --rpc-url "$RPC")
ok "Bar del Corso: community credit = $MERCHANT_AFTER_REDEEM (prima: $MERCHANT_AFTER_SPEND, -$MERCHANT_AFTER_SPEND). Supply totale = $SUPPLY_AFTER_REDEEM (prima: $SUPPLY_BEFORE_REDEEM, -$MERCHANT_AFTER_SPEND, bruciato)."

info ""
info "Contro-prova: Dave (cittadino, nessuna MerchantMembership) prova a"
info "redimere -- ci si aspetta un revert:"
OUT=$(cast send "$CREDIT" "redeem(uint256)" 0 --private-key "$PK_DAVE" --rpc-url "$RPC" 2>&1)
if echo "$OUT" | grep -qi "NotAuthorizedRecipient"; then
    ok "redeem RIFIUTATO (NotAuthorizedRecipient): solo un'impresa con iscrizione attiva puo' chiudere il circuito."
else
    die "redeem da un cittadino avrebbe dovuto fallire con NotAuthorizedRecipient, invece:\n$OUT"
fi


# ---------------------------------------------------------------------------
# Riepilogo finale
# ---------------------------------------------------------------------------
section "Riepilogo finale"
printf "\n  %-6s %-42s %-12s %s\n" "ID" "Progetto" "Esito" "Coniato?" >&2
printf "  %-6s %-42s %-12s %s\n" "--" "--------" "-----" "--------" >&2
printf "  %-6s %-42s %-12s %s\n" "#$PID_A" "Pulizia del parco" "$(status_name "$(get_status "$PID_A")")" "si' (2 performer)" >&2
printf "  %-6s %-42s %-12s %s\n" "#$PID_B" "Verniciatura panchine pubbliche" "$(status_name "$(get_status "$PID_B")")" "si' (2 performer)" >&2
printf "  %-6s %-42s %-12s %s\n" "#$PID_C" "Restauro fontana comunale" "$(status_name "$(get_status "$PID_C")")" "no" >&2

info ""
info "Totale reale on-chain:"
info "  CommunityCredit in circolazione (totalSupply, vero ERC-20): $(cast call "$CREDIT" "totalSupply()(uint256)" --rpc-url "$RPC")"
info "  Bar del Corso (impresa iscritta): community credit = $(credit_balance "$ADDR_MERCHANT") (azzerato dal redeem)"
TOTAL_POP=0; TOTAL_REP=0
for addr in "$ADDR_ALICE" "$ADDR_BOB" "$ADDR_CAROL" "$ADDR_DAVE" "$ADDR_ELENA"; do
    TOTAL_POP=$((TOTAL_POP + $(pop_balance "$addr")))
    TOTAL_REP=$((TOTAL_REP + $(reputation_of "$addr")))
done
info "  Badge ProofOfParticipation totali (somma balanceOf sui 5 cittadini): $TOTAL_POP"
info "  Reputazione totale accumulata (somma reputationOf sui 5 cittadini): $TOTAL_REP"
info "(Attesi: 500 community credit coniati [200 da A + 300 da B, 0 da C], di cui $SPEND"
info "spesi da Bob da Bar del Corso e poi bruciati col redeem -> supply finale attesa"
info "$((500 - SPEND)); 4 badge; reputazione $((REPUTATION_INCREMENT * 4)) [2 performer x 2"
info "progetti confermati, A e B]; 0 dal progetto C, Rejected.)"

info ""
info "CivicProject: $CP"
printf "\n${BOLD}${GREEN}Demo completata con successo.${RESET}\n"
