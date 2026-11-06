# Newdevmon

Newdevmon stuurt je een e-mail zodra een **nieuw apparaat** verbinding maakt met je netwerk, zowel op het hoofdnetwerk als op de gastnetwerken. Het is een script voor routers met [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) en draait vanuit het amtm-menu, met een eigen menu in je SSH-sessie.

Ontwikkeld en getest op een ASUS RT-BE86U.

## Wat het doet

- Controleert elke minuut (instelbaar) alle LAN-bridges: `br0` is het hoofdnetwerk, `br1`, `br2`, enzovoort zijn gastnetwerken.
- Een apparaat telt als **nieuw** zolang het MAC-adres niet in de lijst met bekende apparaten staat.
- Stuurt één e-mail per controle met alle nieuwe apparaten, gesorteerd per netwerk: naam, MAC-adres, IP-adres, netwerk en tijdstip.
- Gebruikt de e-mailinstellingen die je al in amtm hebt ingesteld (`amtm` > `em`). Er is geen apart account of wachtwoord nodig.
- Herkent privé/willekeurige MAC-adressen (iPhone, Android, Windows) en markeert die in de mail.
- Controleert dagelijks of er een nieuwere versie op GitHub staat en installeert die alleen na jouw bevestiging.

## Vereisten

- Een ASUS-router met Asuswrt-Merlin en amtm.
- SSH aan, en **Enable JFFS custom scripts and configs** aan onder Administration > System.
- E-mail ingesteld in amtm. Controleer dit met `amtm` > `em` > optie 11 (testmail).

## Installatie

Log in op de router via SSH en voer uit:

```sh
curl -fsSL -o /jffs/scripts/newdevmon.sh https://raw.githubusercontent.com/plompie010/Newdevmon/main/newdevmon.sh
chmod 755 /jffs/scripts/newdevmon.sh
sh /jffs/scripts/newdevmon.sh
```

In het menu:

1. Kies `5` om een testmail te versturen.
2. Kies `i` om de cronjob en de opstarthook te installeren.

Wil je het script ook in amtm zien? Open in amtm de optie `p` (personal script settings) en voeg `/jffs/scripts/newdevmon.sh` toe.

Bij de eerste controle worden **alle apparaten die nu verbonden zijn** als nieuw gemeld. Wil je dat niet, kies dan eerst `6` ("Alle nu verbonden apparaten als bekend markeren").

## Het menu

Start het script zonder argumenten in een SSH-sessie (of via amtm):

| Optie | Doet |
|---|---|
| `1` | Controle nu uitvoeren |
| `2` | Nu verbonden apparaten tonen (nieuwe apparaten gemarkeerd) |
| `3` | Bekende apparaten tonen, gegroepeerd per netwerk |
| `4` | Log lezen |
| `5` | Testmail versturen |
| `6` | Alle nu verbonden apparaten als bekend markeren |
| `7` | Een apparaat vergeten, zodat het opnieuw gemeld wordt |
| `8` | Controle-interval wijzigen (1 tot 59 minuten) |
| `9` | Controleren op updates en installeren |
| `g` | Mail bij nieuwe versie aan of uit |
| `r` | Vorige versie terugzetten |
| `i` | Cronjob en opstarthook installeren |
| `u` | Cronjob en opstarthook verwijderen |
| `e` | Afsluiten |

Er is ook een opdrachtregel voor gebruik in scripts:

```sh
newdevmon.sh [menu|run|cron|install|uninstall|baseline|test|list|log|forget MAC|update-check|update [-y]|rollback]
```

## Hoe het werkt

Het script leest de DHCP-leases (`/var/lib/misc/dnsmasq.leases`) en de ARP-tabel (`/proc/net/arp`) en voegt die samen op MAC-adres. Het netwerk volgt uit de bridge van het apparaat. Bekende apparaten staan in `/jffs/addons/newdevmon/known_devices.txt`; instellingen en log staan in dezelfde map.

Mislukt het versturen van de mail, dan blijven de apparaten "nieuw" en probeert het script het bij de volgende controle opnieuw.

## Beperkingen

- **Willekeurige MAC-adressen.** Telefoons gebruiken per netwerk een privé-adres. Dat blijft meestal gelijk, maar verandert na "netwerk vergeten" of een reset. Je krijgt dan een melding voor wat eigenlijk een bekend apparaat is.
- **Korte verbindingen.** Een apparaat dat korter dan een controle-interval verbonden is, zonder DHCP-lease, kan gemist worden.
- **Naam van het netwerk.** Gastnetwerken heten "Gastnetwerk (brX)". Extra netwerken uit Guest Network Pro krijgen dezelfde benaming.

## Updates

Het script controleert elke dag om 05:23 of er in deze repo een hogere `VERSION` staat. Is dat zo, dan zie je dat in de kop van het menu en, als je dat aanzet (`g`), ook in een e-mail. Installeren gaat alleen na bevestiging via optie `9`.

Voor het vervangen controleert het script dat het gedownloade bestand een shellscript is, dat het bij Newdevmon hoort, dat de syntax klopt en dat er een versienummer in staat. Vóór elke update maakt het een backup. De laatste drie bewaart het in `/jffs/addons/newdevmon/backup/`. Met `r` zet je de vorige versie terug.

De update-bron (deze repo) staat vast in het script en is niet instelbaar.

## Verwijderen

1. Kies in het menu `u` om de cronjobs en de opstarthook te verwijderen.
2. Verwijder eventueel de regel in amtm (`p`).
3. Verwijder de bestanden:

```sh
rm /jffs/scripts/newdevmon.sh
rm -r /jffs/addons/newdevmon
```

## Problemen oplossen

- **Testmail mislukt.** Controleer eerst of de testmail in amtm zelf werkt (`amtm` > `em` > 11). Het script gebruikt dezelfde instellingen. Zie anders het log (optie `4`).
- **Er komt geen melding.** Kijk bij optie `2` of het apparaat in de lijst staat, en bij optie `3` of het al als bekend is opgeslagen.
- **Cronjob verdwenen na een herstart.** Draai optie `i` opnieuw. Dit zet de regel in `/jffs/scripts/services-start`.


## Licentie

Newdevmon is vrije software onder de **GNU General Public License, versie 3 of (naar keuze) een latere versie**. Zie het bestand [LICENSE](LICENSE).

Het script wordt verspreid zonder enige garantie. Gebruik het op eigen risico.
