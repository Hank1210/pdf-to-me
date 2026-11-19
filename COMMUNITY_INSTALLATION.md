# PDF to me Community installieren

[English version](COMMUNITY_INSTALLATION_EN.md)

PDF to me ist kostenlos und erscheint nur als Community-Ausgabe. Sie ist ad hoc signiert und nicht von Apple
notarisiert. macOS zeigt deshalb beim ersten Start eine Sicherheitswarnung.

Voraussetzung: ein Mac mit macOS 14 oder neuer, mit Apple Silicon oder Intel.

## Download prüfen

1. Laden Sie aus demselben [GitHub Release](https://github.com/Hank1210/pdf-to-me/releases) die ZIP-Datei
   `PDF-to-me-<Version>-Community-macOS.zip` und die gleichnamige `.sha256`-Datei.
2. Öffnen Sie das Terminal, wechseln Sie in den Download-Ordner und prüfen Sie das Archiv, zum Beispiel für 1.1.0:

   ```sh
   cd ~/Downloads
   shasum -a 256 -c PDF-to-me-1.1.0-Community-macOS.zip.sha256
   ```

3. Das Terminal muss `OK` melden. Installieren Sie die App nicht, wenn die Prüfung fehlschlägt.

## Installieren

1. Entpacken Sie die ZIP-Datei.
2. Ziehen Sie „PDF to me“ in den Ordner „Programme“.
3. Öffnen Sie die App mit einem Doppelklick. macOS meldet, dass es die App nicht überprüfen kann. Klicken Sie auf
   „Fertig“ bzw. „OK“.
4. Öffnen Sie „Systemeinstellungen → Datenschutz & Sicherheit“. Unten steht ein Hinweis zu „PDF to me“. Klicken Sie
   auf „Dennoch öffnen“ und bestätigen Sie mit Ihrem Passwort oder Touch ID.
5. Bestätigen Sie im nächsten Dialog mit „Öffnen“.

Unter macOS 14 geht es auch kürzer: Klicken Sie in „Programme“ mit der rechten Maustaste auf „PDF to me“, wählen Sie
„Öffnen“ und bestätigen Sie erneut mit „Öffnen“.

Geben Sie die App nur frei, wenn Sie sie von der GitHub-Seite des Projekts geladen haben und die Prüfsumme stimmt.

## Erster Start

Die App braucht keine Einrichtung, kein Konto und keine Freigaben. Sie zeigt ein Startfenster: Ziehen Sie eine PDF
hinein, klicken Sie auf „Datei öffnen …“ oder wählen Sie eine zuletzt benutzte Datei.

## Aktualisieren

Es gibt keine automatische Aktualisierung. Neue Versionen erscheinen auf GitHub Releases.

1. Speichern Sie offene Arbeit und beenden Sie PDF to me mit ⌘Q.
2. Prüfen und entpacken Sie die neue Version wie oben beschrieben.
3. Ziehen Sie „PDF to me“ in „Programme“ und ersetzen Sie die alte App.
4. macOS kann die Freigabe aus „Installieren“ erneut verlangen, weil jede Community-Ausgabe neu signiert ist.

Die Daten der App bleiben erhalten, auch die Sicherung ungespeicherter Arbeit.

## Entfernen

1. Beenden Sie PDF to me und ziehen Sie die App aus „Programme“ in den Papierkorb.
2. Wenn Sie auch die Daten der App entfernen möchten, löschen Sie diese Ordner:
   - `~/Library/Application Support/PDF to me`
   - `~/Library/Logs/PDF-to-me`

Ihre PDFs bleiben unberührt.

## Selbst bauen

Statt die Community-Ausgabe zu laden, können Sie die App selbst aus dem Quellcode bauen. Die Anleitung steht im
[README](README.md#building-from-source).
