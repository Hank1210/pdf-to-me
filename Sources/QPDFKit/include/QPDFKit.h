// C-Schnittstelle zu qpdf (C++). Swift ruft nur diese Funktionen auf; qpdf selbst bleibt dahinter verborgen.
//
// Ein Composer setzt aus Seiten mehrerer Quell-PDFs eine neue PDF zusammen, strukturell (Seiten werden kopiert, nicht
// neu gezeichnet). Er erhält Text, Anmerkungen, interne Links, das Inhaltsverzeichnis und Formularfelder und kann die
// neue Datei mit einem Passwort schützen. Ein Composer ist nicht threadsicher; der Swift-Wrapper sperrt.
#ifndef QPDFKIT_H
#define QPDFKIT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Version der eingebauten qpdf-Bibliothek, z. B. "12.4.2".
const char *qpdfkit_version(void);

/// Ergebnis einer Funktion. Bei einem Fehler steht eine (englische) Beschreibung in `error`.
typedef enum {
    QK_OK = 0,
    QK_WRONG_PASSWORD = 1,
    QK_DAMAGED = 2,
    QK_FAILED = 3,
} QKStatus;

typedef struct QKComposer QKComposer;

QKComposer *qk_composer_new(void);
void qk_composer_free(QKComposer *composer);

/// Fügt eine Quelle aus dem Speicher hinzu; die Bytes werden kopiert. `password` darf NULL sein. `title` ist der
/// Name für das Inhaltsverzeichnis, wenn mehrere Quellen eines haben. Schreibt den Index der Quelle nach `index`.
QKStatus qk_add_source(QKComposer *composer, const void *bytes, size_t length, const char *password,
                       const char *title, int *index, char *error, size_t error_length);

/// Seitenzahl einer hinzugefügten Quelle.
int qk_source_page_count(QKComposer *composer, int source);

/// Hängt Seite `page_index` (ab 0) der Quelle `source` an, gedreht um `rotation` Grad im Uhrzeigersinn (Vielfaches
/// von 90). Dieselbe Seite darf mehrfach vorkommen.
void qk_add_page(QKComposer *composer, int source, int page_index, int rotation);

/// Fügt eine Überlagerung hinzu: eine PDF, deren erste Seite über Seiten gelegt werden kann (z. B. eine
/// unsichtbare Textebene). Die Bytes werden kopiert. Schreibt den Index der Überlagerung nach `index`.
QKStatus qk_add_overlay(QKComposer *composer, const void *bytes, size_t length, int *index, char *error,
                        size_t error_length);

/// Wie `qk_add_page`, legt aber die Überlagerung `overlay` über die Seite: eingepasst in den sichtbaren Ausschnitt
/// (CropBox) und so, dass sie zur Seite steht, wie die Quelle sie anzeigt (eigenes /Rotate). Die zusätzliche
/// Drehung `rotation` dreht Seite und Überlagerung gemeinsam. Der Inhalt der Seite bleibt unverändert.
void qk_add_page_with_overlay(QKComposer *composer, int source, int page_index, int rotation, int overlay);

/// Setzt die Seiten zusammen und schreibt die neue Datei nach `path`. `password` (darf NULL sein) schützt sie mit
/// AES-256. Die Metadaten (Titel, Autor, Thema, Stichwörter) kommen aus der ersten Quelle, als Ersteller steht
/// `creator`.
QKStatus qk_write(QKComposer *composer, const char *path, const char *password, const char *creator, char *error,
                  size_t error_length);

/// Prüft eine PDF-Datei wie `qpdf --check`: öffnen (mit `password`, darf NULL sein), alle Objekte lesen und alle
/// Datenströme dekodieren. Schreibt die Seitenzahl nach `page_count` und die Zahl der Warnungen nach `warnings`.
QKStatus qk_check(const char *path, const char *password, int *page_count, int *warnings, char *error,
                  size_t error_length);

#ifdef __cplusplus
}
#endif

#endif
