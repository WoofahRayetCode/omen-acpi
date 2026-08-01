# Analisi di `NVDE` — HP OMEN 16-ap0xxx / 8E35 / BIOS F.13

Domanda: scrivere `NVDE = 1` durante `_PTS` prima di `OMPR = 3` e `_PS3()`
ha un effetto sul percorso di spegnimento?

**Risposta: sì, ma scriverlo non serve.** `NVDE` è la condizione di guardia del
metodo che la patch stessa invoca per spegnere la GPU — quindi è rilevante, e
la versione precedente di questo documento, basata sul solo DSDT, sbagliava a
dichiararlo inerte. Ma il driver NVIDIA lo imposta già in ogni condizione che
conta, incluso il dopo-resume (misurato, §5). Le due varianti di 2.1.9 vanno
bene così.

Strumento: `nvde-audit.py` (in questa cartella). Sorgenti: `dsdt.dsl`
(23.227 righe, 614 metodi) **e i 23 SSDT** della stessa raccolta.

## 0. Perché la conclusione precedente era sbagliata

L'analisi era stata fatta sul solo DSDT. Il DSDT dichiara come `External` i
metodi che vivono negli SSDT, e `nvde-audit.py` risolve le chiamate per nome
corto di quattro caratteri senza tenere conto dello scope. Due conseguenze:

| Effetto | Conseguenza sull'analisi |
|---|---|
| `_PS3` è definito 14 volte nel DSDT (porte USB/PCIe) | la chiamata `\_SB.PCI0.GPP0.PEGP._PS3 ()` veniva risolta su un corpo qualsiasi e innocuo |
| il vero `PEGP._PS3` è in `ssdt10` | il suo corpo non è mai stato letto |

Lo strumento ora segnala entrambi i casi (`PUNTI CIECHI`, `NOMI AMBIGUI`) e si
rifiuta di dichiarare chiusa una conclusione che non lo è.

## 1. Che cosa è `NVDE`

DSDT riga 219:

```asl
Name (NVDE, Zero)
```

`ssdt10` riga 212 la importa:

```asl
External (NVDE, UnknownObj)
```

È una variabile di namespace globale, non un campo di `OperationRegion`.
Scriverla non tocca EC, SMI o registri: conta solo perché altri metodi AML la
rileggono. Il punto è che la rileggono, e nel posto peggiore.

## 2. La catena reale dello spegnimento

Il patch S5 aggiunge in `_PTS(5)`:

```asl
Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)
\_SB.PCI0.GPP0.PEGP._PS3 ()
```

`OMPR` è dichiarato in `ssdt10` riga 714 (`Name (OMPR, 0x02)`, scope
`\_SB.PCI0.GPP0.PEGP`). Il vero `PEGP._PS3` è in `ssdt10` riga 761:

```asl
Method (_PS3, 0, NotSerialized)
{
    If ((OMPR == 0x03))
    {
        If ((GPRF != One))
        {
            VGAB = VGAR
        }

        \_SB.PCI0.GPP0.PG00._OFF ()
        DGPS = One
        OMPR = 0x02
    }

    _PSC = 0x03
}
```

`PG00` è la power resource della GPU (`ssdt10` riga 555, scope
`\_SB.PCI0.GPP0`). Il suo `_OFF` (riga 622) comincia così:

```asl
Method (_OFF, 0, Serialized)
{
    If ((NVDE != One))
    {
        Return (Zero)
    }

    If ((GSTA () != One))
    {
        Return (Zero)
    }
    ...
}
```

Catena completa:

```
_PTS(5) → OMPR = 3 → PEGP._PS3() → PG00._OFF() → If (NVDE != 1) Return
```

**Con `NVDE != 1` lo spegnimento della GPU non avviene.** Lo stesso guardiano
è in `PG00._ON` (riga 569).

## 3. Chi scrive `NVDE`

| Tabella | Riga | Metodo | Operazione |
|---|---|---|---|
| dsdt | 22900 | `WAK` | `NVDE = Zero` al risveglio da S3/S4 |
| ssdt10 | 1032 | `PEGP._DSM` | `NVDE = One` (GUID `d4a50b75-…`, → `NBCI`) |
| ssdt10 | 1038 | `PEGP._DSM` | `NVDE = One` (GUID `a3132d01-…`, → `_GPS`) |
| ssdt10 | 1044 | `PEGP._DSM` | `NVDE = One` (GUID `cbeca351-…`, → `NVJT`) |
| ssdt10 | 1050 | `PEGP._DSM` | `NVDE = One` (GUID `a486d8f8-…`, → `NVOP`) |

Sono i quattro GUID `_DSM` standard di NVIDIA Optimus. Li invoca il driver
NVIDIA. Quindi:

- il firmware **imposta** `NVDE = 1`, contrariamente a quanto affermato prima;
- i rami `If ((NVDE == One))` del DSDT **non** sono codice morto;
- con il driver NVIDIA caricato, `NVDE` vale normalmente 1 allo spegnimento, ed
  è per questo che la patch minima funziona senza scrivere `NVDE`.

## 4. Chi legge `NVDE`

| Tabella | Riga | Metodo | Raggiungibile da `_PTS` patchato |
|---|---|---|---|
| ssdt10 | 622 | `PG00._OFF` | **sì**, via `_PS3` |
| ssdt10 | 569 | `PG00._ON` | no |
| dsdt | 13296, 13317 | `GM22` | no (dispatch WMI dal sistema operativo) |
| dsdt | 21956 | `_Q8D` | no (query EC asincrona) |

## 5. Il caso sospetto, misurato: non si verifica

`WAK` azzera `NVDE` al risveglio da S3 (`Arg0 == 0x03`) e S4 (`0x04`). Se dopo
un risveglio il driver non rieseguisse nessuno dei quattro `_DSM` prima dello
spegnimento, `NVDE` resterebbe a `0`, `PG00._OFF()` uscirebbe subito e la patch
S5 non avrebbe alcun effetto.

**Misurato il 2026-08-01: non succede.** Il driver riarma `NVDE` da solo, circa
1,3 secondi dopo il resume.

### Metodo

Il firmware si autoinstrumenta. `_GPS` è definito una sola volta (`ssdt10` riga
1270) ed è chiamato da un solo punto, `ssdt10` riga 1039:

```asl
If ((Arg0 == ToUUID ("a3132d01-8cda-49ba-a52e-bc9d46df6b81")))
{
    NVDE = One
    Return (\_SB.PCI0.GPP0.PEGP._GPS (Arg0, Arg1, Arg2, Arg3))
}
```

`_GPS` comincia con `Store ("------- NV GPS DSM --------", Debug)`. Poiché
l'unica via d'accesso a `_GPS` passa dalla riga che scrive `NVDE = One`, vedere
quella stringa nel log del kernel **è** la prova che `NVDE` è appena stato
messo a 1. Il kernel instrada le `Debug` di AML in `dmesg` con
`/sys/module/acpi/parameters/aml_debug_output`.

Il method tracing ACPI (`trace_method_name` + `trace_state`) è stato provato
per primo e non produce output su questo kernel, nemmeno su un metodo di
controllo eseguito di sicuro come `\_SB.BAT0._BST`. Non usarlo.

### Dati

```text
[ 3637.540856] ACPI Debug:  "HP WMI Command 0x04 (BIOS Read)"      ← resume
[ 3638.798096] ACPI Debug:  "------- NV GPS DSM --------"          ← NVDE = One
[ 3638.798157] ACPI Debug:  "GPS fun 19"
[ 3638.798784] ACPI Debug:  "------- NV GPS DSM --------"
[ 3638.798827] ACPI Debug:  "GPS fun 18"
[ 3638.798988] ACPI Debug:  "------- NV GPS DSM --------"
[ 3638.799063] ACPI Debug:  "   GPS fun 42"
[ 3639.845830] ACPI Debug:  "------- NVPCF DSM --------"
```

Tre chiamate `_GPS` a 1,26 s dal resume, senza alcuna interazione con la GPU
discreta. `NVPCF` è un `_DSM` distinto e non tocca `NVDE`.

### Cosa resta fuori dalla misura

- vale finché è caricato il driver NVIDIA proprietario: senza di esso nessuno
  imposta `NVDE` e `PG00._OFF()` non spegne nulla;
- uno spegnimento avviato entro ~1,3 s dal resume cadrebbe prima del riarmo,
  caso irrealistico con `systemctl poweroff`;
- misurato su S3. L'ibernazione S4 percorre lo stesso `WAK`, ma non è stata
  osservata direttamente.

## 6. Conclusione

Due risultati distinti, e vanno tenuti separati.

**Sul piano dell'analisi:** `NVDE` non è inerte. Il documento precedente
sbagliava. `NVDE = 1` nel vecchio Combined armava esattamente la guardia che
abilita `PG00._OFF`, cioè il metodo che la patch invoca per spegnere la GPU. La
rimozione fatta in 2.1.6/2.1.7 non era una semplificazione neutra: ha reso la
correzione dipendente da chi imposta `NVDE`.

**Sul piano pratico:** quella dipendenza è soddisfatta. Il driver NVIDIA riarma
`NVDE` a ogni resume in circa un secondo, misurato al punto 5. Anche l'unico
scenario in cui la patch minima poteva restare inerte non si presenta.

**Raccomandazione: non aggiungere la terza variante.** Le due varianti di
2.1.9 sono corrette così. Reintrodurre `NVDE = 1` renderebbe la patch autonoma
sulla carta, ma comprerebbe un margine che non serve pagandolo con un rischio
reale: fra `_PTS(5)` e lo spegnimento effettivo, con `NVDE = 1` diventano
eseguibili i rami di `_Q8D` (evento EC `0x8D`) e `GM22` (comando WMI `20008h`
type `0x20`), mai collaudati in quella finestra.

Va inoltre notato che `NVDE = 1` non sarebbe comunque sufficiente da solo:
`PG00._OFF` ha una seconda guardia, `If ((GSTA () != One)) { Return (Zero) }`.
Forzare `NVDE` rende la patch autonoma, non incondizionata.

La conclusione va rivista se cambia il presupposto: driver NVIDIA sostituito o
non caricato, oppure aggiornamento del BIOS che modifichi `ssdt10`. In quel
caso ripetere la misura del punto 5 prima di fidarsi.

## 7. Come riprodurre

```bash
./nvde-audit.py --self-test
./nvde-audit.py ~/omen-*acpi-source-*.tar.gz
./nvde-audit.py --scan-all DIRECTORY_CON_TUTTI_I_DSL
./nvde-audit.py --symbol OMPR --scan-all DIRECTORY_CON_TUTTI_I_DSL
```

L'archivio prodotto da `omen-acpi collect` contiene solo `dsdt.dsl`. Per avere
anche gli SSDT servono i `.dat` di `acpixtract` decompilati singolarmente:

```bash
for f in ssdt*.dat; do iasl -d "$f"; done
```

Per ripetere la misura del punto 5:

```bash
echo 1 | sudo tee /sys/module/acpi/parameters/aml_debug_output
echo "=== RESUME-TEST ===" | sudo tee /dev/kmsg
systemctl suspend
# risvegliare, attendere un minuto senza toccare la GPU discreta
sudo dmesg | sed -n '/RESUME-TEST/,$p' | grep -i 'ACPI Debug'
echo 0 | sudo tee /sys/module/acpi/parameters/aml_debug_output
```

Cercare `------- NV GPS DSM --------`, `<<< NBCI >>>`, `<<< NVOP >>>` o
`------- NV JT DSM --------`: sono i quattro handler `_DSM` che scrivono
`NVDE = One`. `------- NVPCF DSM --------` non conta, non tocca `NVDE`.
