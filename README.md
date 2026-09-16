# CivicDAO — Contratti e demo

Implementazione in Solidity dei contratti della CivicDAO descritta nella
tesi, con due demo end-to-end che eseguono transazioni **vere** su un nodo
Anvil locale.

Stack: **Solidity 0.8.28 + OpenZeppelin v5 + Foundry + Anvil**.

Il sistema ha due "binari" di governance, entrambi ancorati alla stessa
identità digitale (`CitizenshipSBT`, soulbound, onboarding EIP-712):

- **Binario pubblico** (`ParticipatoryBudget`): bilancio partecipativo a
  voto quadratico su uno slate di proposte fissato dal Comune.
- **Binario privato** (`CivicProject`): macchina a stati che governa l'intero
  ciclo di vita di un progetto civico, dalla proposta alla conferma o al
  rigetto, collegata a un'economia di incentivi reale
  (`CommunityCredit`, `ProofOfParticipation`, `Reputation`,
  `MerchantMembership`).

Per il dettaglio contratto-per-contratto (struct, funzioni, errori, grafo
delle dipendenze) vedi [architecture.md](architecture.md). Questo README si
concentra su come lanciare ed eseguire le demo.

---

## Prerequisiti

Installare Foundry (una volta sola):

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Le dipendenze (OpenZeppelin, forge-std) sono già incluse nella cartella
`lib/`. Se mancassero:

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
```

---

## Struttura del progetto

```
demo-participatory-budget.sh   # demo del binario pubblico (QV), Anvil incluso
demo-privato.sh                 # demo del binario privato (CivicProject), economia reale, Anvil incluso
src/
  CitizenshipSBT.sol       # identità cittadina soulbound (ERC-721 + ERC-5192), onboarding EIP-712
  ParticipatoryBudget.sol  # binario pubblico: voto quadratico, quorum, esito motivato
  CivicProject.sol         # binario privato: macchina a stati del progetto civico
  CommunityCredit.sol      # economia: community credit (ERC-20, spendibile solo verso imprese iscritte)
  MerchantMembership.sol   # iscrizione annuale imprese (ERC-721 soulbound), consultata da CommunityCredit
  ProofOfParticipation.sol # economia: badge PoP (ERC-721 soulbound, molti per indirizzo)
  Reputation.sol           # economia: reputazione non trasferibile, decadimento lazy, soglia per ruoli (sez. 4.3.4)
  interfaces/
    IERC5192.sol               # standard minimo di soulbound-ness
    ICommunityCredit.sol       # frontiera verso il community credit
    IProofOfParticipation.sol  # frontiera verso il badge PoP
    IReputation.sol            # frontiera verso la reputazione
    IJury.sol                  # frontiera verso la giuria (ancora solo mock)
test/
  CitizenshipSBT.t.sol                     # identità, soulbound, anti-replay (nessuna revoca: definitiva)
  ParticipatoryBudget.t.sol                # QV, budget quadratico, quorum, obbligo di motivazione
  CivicProject.t.sol                       # macchina a stati completa (mock delle 4 interfacce di frontiera)
  CivicProjectEconomyIntegration.t.sol     # stessa macchina, fino a Confirmed, con CommunityCredit/PoP REALI
  CivicProjectReputationIntegration.t.sol  # stessa macchina, fino a Confirmed, con Reputation REALE
  CommunityCredit.t.sol                    # solo MINTER_ROLE conia; transfer solo verso imprese iscritte attive
  MerchantMembership.t.sol                 # solo ISSUER_ROLE conia; soulbound; isActiveMember corretto
  ProofOfParticipation.t.sol               # solo MINTER_ROLE conia; soulbound; tokenData corretto
  Reputation.t.sol                         # solo SCORER_ROLE scrive; accumulo; decadimento lazy lineare; soglia
  mocks/
    CivicProjectMocks.sol      # mock delle 4 interfacce di frontiera + CitizenshipSBT minimale, usati dai test

```

> Nota: `Jury` resta mock in tutto il progetto: l'interfaccia `IJury` è
> soddisfatta solo da `test/mocks/CivicProjectMocks.sol` (e dall'omologo
> `MockJury` deployato dagli script/demo).

---

## Le due demo

Entrambe sono **un solo comando**: avviano un nodo Anvil locale, eseguono
transazioni vere e lo spengono da sole all'uscita. Usano solo gli account
di sviluppo predefiniti di Anvil. Ogni sezione narrata si ferma in attesa di un "Invio" da terminale.

### 1) `./demo-participatory-budget.sh` — binario pubblico (Quadratic Voting)

Narrata in inglese. Autosufficiente: fa il deploy di **entrambi** i
contratti che le servono (`CitizenshipSBT` e `ParticipatoryBudget`) e
l'onboarding dei cittadini al proprio interno.

1. **Elettorato**: deploy di `CitizenshipSBT` (Comune = account #0 di Anvil,
   admin + `ISSUER_ROLE`) e `ParticipatoryBudget` (Comune =
   `MUNICIPALITY_ROLE`); onboarding reale di 5 cittadini (account #1-5) via
   `mintWithAuth` con firma EIP-712 del Comune. Il nullifier è un commitment
   con chiave al codice fiscale del cittadino (`keccak(codiceFiscale ||
   segreto del Comune)`).
2. **Apertura round**: il Comune apre un round con 3 proposte (etichette +
   CID IPFS fittizi), 100 crediti QV a testa, finestra di voto di 30
   secondi.
3. **Voto**: tutti e 5 i cittadini votano con schede diverse: Alice
   concentra tutto il budget su una sola proposta (10 voti = 100 crediti, il
   massimo concentrabile in QV: costo = voti²), gli altri distribuiscono i
   voti su più proposte. Ogni scheda viene narrata con il suo costo
   quadratico.
4. **Chiusura**: la finestra scade e chiunque può chiudere il round
   (permissionless). Lo script avanza l'orologio della chain con le RPC
   proprie di Anvil (`evm_increaseTime` + `evm_mine`, via `cast rpc`),
   deterministico e istantaneo.
5. **Risultati**: tabella dei punteggi per proposta, vincitrice calcolata
   dai punteggi letti on-chain (non cablata nello script), ed esito del
   quorum (10% dell'elettorato registrato al momento dell'apertura del
   round).
6. **Esito motivato**: il Comune registra l'esito. Prima una contro-prova:
   un tentativo di segnare la proposta vincente `NotExecuted` **senza** un
   CID di motivazioni, che deve fallire con `ReasonsRequired`. Poi la
   registrazione corretta con un CID, a dimostrare che l'obbligo di
   motivazione è imposto dal contratto.

### 2) `./demo-privato.sh` — binario privato (`CivicProject`), economia reale

Deploya `CivicProject` collegato alle implementazioni
**reali** di tre delle quattro interfacce di frontiera: `CommunityCredit`
(ERC-20), `ProofOfParticipation` (ERC-721 soulbound) e `Reputation` più `MerchantMembership` (di cui `CommunityCredit` dipende). L'unica
rimasta mock è `IJury` (`MockJury`): non ha ancora un'implementazione reale
nel progetto.

Attori (account Anvil di default): #0 = Comune (confinato al proprio ruolo
di certificatore d'identità, `ISSUER_ROLE` solo su `CitizenshipSBT`); #1-5 =
cittadini (Alice, Bob, Carol, Dave, Elena), onboardati con lo stesso flusso
EIP-712 reale della prima demo; #6 = Giulia, la giurata (`IJury.isJuror`);
#7 = "Bar del Corso", un'impresa che aderisce alla DAO; #8 = l'ETS (Ente del
Terzo Settore), l'ente giuridico della DAO stessa, admin/issuer di tutta l'economia interna (`MerchantMembership`,
`CommunityCredit`, `ProofOfParticipation`, `Reputation`) e chi concede a
`CivicProject` i ruoli `MINTER_ROLE`/`SCORER_ROLE` su di essa.

1. **Deploy e ruoli**: `CitizenshipSBT`, `MerchantMembership`,
   `CommunityCredit`, `ProofOfParticipation`, `Reputation`, `MockJury`,
   `CivicProject` (in quest'ordine, per risolvere la dipendenza circolare —
   `CivicProject` ha bisogno degli indirizzi dell'economia, l'economia ha
   bisogno dell'indirizzo di `CivicProject` per concedergli un ruolo).
   L'ETS, non il Comune, concede `MINTER_ROLE`/`SCORER_ROLE` a
   `CivicProject`.
2. **Tre progetti**, per attraversare tutti i rami della macchina a stati:
   - **Progetto A — "Pulizia del parco"** (percorso ottimistico): proposta
     → consenso on-chain di tutto il team (obbligatorio *prima* del voto) →
     voto vincolante (un cittadino, un voto; quorum al 10% dell'elettorato
     snapshot) → `Funded` → caricamento delle prove → `Submitted` →
     **nessuna contestazione** entro la finestra di verifica (default di
     contratto, 7 giorni) → `Confirmed` da un cittadino qualsiasi
     (permissionless). Effetti narrati per ciascun performer: conio di
     community credit (in parti uguali sui soli performer effettivi, non su
     tutto il team), badge PoP, incremento di reputazione; più l'evento
     `ReimbursementDue`.
   - **Progetto B — "Verniciatura delle panchine pubbliche"**
     (contestazione, verdetto **favorevole**): stesso percorso fino a
     `Submitted`, poi Elena contesta (`Challenged`) e Giulia, la giurata,
     approva la prova → `Confirmed`, stessi conii.
   - **Progetto C — "Restauro della fontana comunale"** (contestazione,
     verdetto **sfavorevole**): Elena contesta di nuovo, ma questa volta
     Giulia respinge la prova → `Rejected`. Verificato on-chain (saldi
     reali, non contatori) che **nulla** viene coniato.
3. **Time-jump**: Lo script usa `evm_increaseTime` + `evm_mine`. Usa i
   default reali di contratto (finestra di voto 3 giorni, verifica 7
   giorni) senza doverli accorciare, perché il salto temporale è comunque
   istantaneo.
4. **Circuito chiuso del community credit** , tutti e tre
   gli stadi:
   1. *conio*: visto al punto 2, verso ciascun performer confermato;
   2. *spesa*: "Bar del Corso" si iscrive alla DAO (`MerchantMembership`,
      certificata dall'ETS dopo un pagamento off-chain). Bob spende metà
      del suo credito lì (`transfer`, saldi prima/dopo su entrambi i lati).
      Contro-prova: Carol prova a mandare credito a Dave, un altro
      cittadino → revert `NotAuthorizedRecipient` (il credito non è mai
      trasferibile cittadino-cittadino);
   3. *redeem*: "Bar del Corso" restituisce alla DAO tutto il credito
      accumulato con `CommunityCredit.redeem`, che lo **brucia** (la supply
      totale scende) ed emette `Redeemed`. Contro-prova: Dave (cittadino,
      nessuna `MerchantMembership`) prova a fare redeem → stesso revert
      `NotAuthorizedRecipient`.
5. **Riepilogo finale**: stato dei tre progetti, community credit in
   circolazione (`totalSupply` reale), saldo residuo dell'impresa (azzerato
   dal redeem), badge PoP e reputazione totali accumulati sui 5 cittadini.

---

## Suite di test

```bash
forge test
```

Attesi **129 test verdi** in 9 suite:

```bash
forge test --match-contract CitizenshipSBTTest -vv                     # 8  -- identità, soulbound, anti-replay
forge test --match-contract ParticipatoryBudgetTest -vv                # 36 -- QV, quorum, obbligo di motivazione
forge test --match-contract CivicProjectTest -vv                       # 48 -- macchina a stati (interfacce mock, isolata)
forge test --match-contract CivicProjectEconomyIntegrationTest -vv     # 1  -- stessa macchina, CommunityCredit/PoP REALI
forge test --match-contract CivicProjectReputationIntegrationTest -vv  # 1  -- stessa macchina, Reputation REALE
forge test --match-contract CommunityCreditTest -vv                    # 12 -- ERC-20: mint, spesa, redeem/burn, circuito chiuso
forge test --match-contract MerchantMembershipTest -vv                 # 8  -- iscrizione annuale, soulbound
forge test --match-contract ProofOfParticipationTest -vv               # 6  -- ERC-721 soulbound, molti per indirizzo
forge test --match-contract ReputationTest -vv                         # 9  -- punteggio non trasferibile, decadimento lazy, soglia
```


## Prossimi passi (non nella demo, già predisposti nel design)

- **Jury reale**: oggi soddisfatta solo da `MockJury`
  (`test/mocks/CivicProjectMocks.sol`). L'implementazione reale seguirebbe
  lo stesso schema di `CommunityCredit`/`ProofOfParticipation`/`Reputation`
  dietro `IJury`, includendo eleggibilità per soglia reputazionale — oggi
  `Reputation.hasReputation` è pronta come primitiva ma non ancora
  agganciata a `Jury`.
- **Liquid democracy**: delega revocabile e per singola materia (RF-06), non
  presente in nessuno dei due binari attuali.
- **Tokenomica di `CommunityCredit`**: cap sulla supply e decadimento dei
  saldi non spesi nel tempo (vedi il `// TODO` in `CommunityCredit.sol`).
- **dApp web** minimale (wallet connect + dashboard proposte/voto).
# tesi-civic-dao
