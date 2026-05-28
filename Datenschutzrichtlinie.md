# Datenschutzrichtlinie für SE Monitor

*Stand: 26.5.2026*

Diese Datenschutzrichtlinie beschreibt, welche Daten die App **SE Monitor** (im
Folgenden „die App") verarbeitet, wie sie verarbeitet werden und welche Rechte Sie als
Nutzer:in haben.

## 1. Verantwortlicher im Sinne der DSGVO

Verantwortlich für die Verarbeitung personenbezogener Daten im Zusammenhang mit der App ist:

> **Stephan Schindewolf**
> [postal address removed]
> [postal address removed]
> Deutschland
>
> E-Mail: schiwo1@gmail.com

## 2. Grundsatz: Keine Datenerhebung durch den Anbieter

SE Monitor ist eine reine Client-App, die ausschließlich auf Ihrer Apple Watch
und in der zugehörigen Komplikations-Erweiterung läuft. **Es gibt keine vom
Anbieter betriebenen Server, keine Analytics, kein Tracking und keine Werbung.** Es
werden weder personenbezogene Daten noch Nutzungsdaten an den Anbieter oder an Dritte
übermittelt.

## 3. Datenverarbeitung auf dem Gerät

Damit die App ihre Funktion erfüllen kann (Anzeige Ihrer eigenen Photovoltaik-Daten aus
dem SolarEdge-Monitoring-Portal), werden folgende Daten **lokal auf Ihrer Apple Watch**
gespeichert:

| Datum | Zweck | Speicherort |
|-------|-------|-------------|
| SolarEdge API-Schlüssel (Account-Level) | Authentifizierung gegenüber der SolarEdge-Monitoring-API | watchOS `UserDefaults` (App-Group) |
| SolarEdge Site-ID | Identifikation Ihrer PV-Anlage | watchOS `UserDefaults` (App-Group) |
| Zwischengespeicherte Momentaufnahmen und 24-Stunden-Verläufe | Anzeige der Charts und Komplikation auch ohne Netzverbindung | watchOS `UserDefaults` (App-Group) |

Die Daten verlassen Ihre Apple Watch ausschließlich, um die nachfolgend beschriebenen
HTTPS-Anfragen an die offizielle SolarEdge-Monitoring-API durchzuführen.

## 4. Direkte Kommunikation mit der SolarEdge-Monitoring-API

Zum Abruf der Anlagendaten stellt die App **ausschließlich verschlüsselte HTTPS-
Verbindungen** zu der offiziellen SolarEdge-Monitoring-API her
(`https://monitoringapi.solaredge.com`). Dabei werden HTTP-GET-Anfragen an die
folgenden Endpunkte gerichtet:

- `GET /sites/list` — einmalige Ermittlung Ihrer Site-ID bei Erstinbetriebnahme
- `GET /site/{id}/overview` — Momentanleistung und Tages-/Lebensdauerenergie
- `GET /site/{id}/powerDetails` — 15-Minuten-Leistungsdaten der letzten 24 Stunden
- `GET /site/{id}/storageData` — Batterietelemetrie der letzten 24 Stunden

Diese Anfragen tragen Ihren persönlichen SolarEdge API-Schlüssel als URL-Parameter
`api_key`, wie es die offizielle SolarEdge API-Spezifikation vorschreibt. Die Antworten
enthalten ausschließlich Daten aus Ihrer eigenen SolarEdge-Installation. Der Anbieter
der App erhält von dieser Kommunikation nichts; sie findet direkt zwischen Ihrer Apple
Watch und den SolarEdge-Servern statt.

Für die Datenverarbeitung durch SolarEdge <img width="45" height="15" alt="SolarEdge Logo_CMYK" src="https://github.com/user-attachments/assets/9bb45e0f-670c-4493-af60-1bfe95c2568b" />
 gelten die Datenschutzbestimmungen von
**SolarEdge Technologies, Inc.** unter <https://www.solaredge.com/legal/privacy-policy>.
Für den Zugriff über das SolarEdge API auf das SolarEdge Monitoring System gelten die Bestimmungen unter <https://monitoring.solaredge.com/solaredge-web/p/license>


## 5. Drittanbieter

Die App nutzt **keine** Drittanbieter-SDKs, keine Werbe- oder Tracking-Dienste, keine
Crash-Reporting-Dienste und keine externen Analyse-Tools.

Die App kommuniziert ausschließlich mit:

1. **Den Servern von SolarEdge Technologies, Inc.** unter
   `monitoringapi.solaredge.com`, ausschließlich zum Abruf Ihrer eigenen Anlagendaten.
2. **Apple-Diensten**, die für den Betrieb von watchOS-Apps systembedingt erforderlich
   sind (z. B. WidgetKit für die Komplikation, App Group für den Datenaustausch
   zwischen Watch-App und Komplikation). Für die Datenverarbeitung durch Apple gelten
   die Datenschutzbestimmungen von Apple Inc.

## 6. Rechtsgrundlage der Verarbeitung (Art. 6 DSGVO)

Soweit auf dem Gerät personenbezogene Daten (insb. Ihr SolarEdge API-Schlüssel)
verarbeitet werden, geschieht dies auf Grundlage von Art. 6 Abs. 1 lit. b DSGVO
(Erfüllung der Funktion, die Sie mit der Installation der App nachgefragt haben) sowie
Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an einem funktionierenden Produkt).

## 7. Speicherdauer

- API-Schlüssel und Site-ID werden gespeichert, bis Sie sie in der App ändern
  („Change API Key") oder die App von Ihrer Apple Watch deinstallieren.
- Zwischengespeicherte Anlagendaten werden bei jedem erfolgreichen Abruf überschrieben
  und beim Deinstallieren der App vollständig entfernt.

## 8. Ihre Rechte

Da der Anbieter der App **keine Daten von Ihnen erhebt oder speichert**, gibt es seitens
des Anbieters auch keine personenbezogenen Daten, auf die sich die folgenden Rechte
beziehen könnten. Vollständigkeitshalber: Nach DSGVO stehen Ihnen grundsätzlich die
folgenden Rechte zu — Auskunft (Art. 15), Berichtigung (Art. 16), Löschung (Art. 17),
Einschränkung der Verarbeitung (Art. 18), Datenübertragbarkeit (Art. 20), Widerspruch
(Art. 21) sowie Beschwerde bei einer Aufsichtsbehörde (Art. 77).

Alle lokal auf Ihrer Apple Watch gespeicherten Daten können Sie jederzeit löschen,
indem Sie die App über „Change API Key" zurücksetzen oder die App deinstallieren. Sie
können Ihren SolarEdge API-Schlüssel zudem jederzeit im SolarEdge-Monitoring-Portal
widerrufen oder rotieren.

## 9. Sicherheit

- Verbindungen zur SolarEdge-API erfolgen ausschließlich über HTTPS (TLS).
- Der API-Schlüssel wird ausschließlich auf Ihrer Apple Watch in den geschützten
  `UserDefaults` der App-Group gespeichert und verlässt das Gerät nur als
  `api_key`-Parameter in HTTPS-Anfragen an `monitoringapi.solaredge.com`.
- SolarEdge empfiehlt, API-Schlüssel alle sechs Monate zu rotieren. Eine Rotation ist
  jederzeit im SolarEdge-Monitoring-Portal möglich; im Anschluss können Sie den neuen
  Schlüssel in der App über „Change API Key" eintragen.

## 10. Hinweis zu Markenrechten

SE Monitor ist ein unabhängiges Drittprodukt. Es steht in keiner geschäftlichen oder
personellen Verbindung zu **SolarEdge Technologies, Inc.** und wird von SolarEdge weder
unterstützt noch gesponsert. „SolarEdge" ist eine eingetragene Marke von SolarEdge
Technologies, Inc.; der Name wird hier nur zur Beschreibung der offiziellen
SolarEdge-Monitoring-API verwendet, deren Daten die App auf Ihrer eigenen Anlage
abrufen kann.

## 11. Änderungen dieser Datenschutzrichtlinie

Diese Datenschutzrichtlinie kann angepasst werden, wenn dies durch geänderte Funktionen
der App oder durch geänderte Rechtslage erforderlich wird. Die jeweils aktuelle Fassung
wird unter der URL veröffentlicht, die Sie im App Store als Datenschutzrichtlinie der
App finden.

## 12. Kontakt

Bei Fragen zu dieser Datenschutzrichtlinie wenden Sie sich bitte an die unter Ziffer 1
genannte Kontaktadresse.
