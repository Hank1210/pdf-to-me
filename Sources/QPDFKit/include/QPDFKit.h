// C-Schnittstelle zu qpdf (C++). Swift ruft nur diese Funktionen auf; qpdf selbst bleibt dahinter verborgen.
#ifndef QPDFKIT_H
#define QPDFKIT_H

#ifdef __cplusplus
extern "C" {
#endif

/// Version der eingebauten qpdf-Bibliothek, z. B. "12.4.2".
const char *qpdfkit_version(void);

#ifdef __cplusplus
}
#endif

#endif
