#include "QPDFKit.h"

#if !__has_include(<qpdf/QPDF.hh>)
#error "qpdf fehlt. Bitte zuerst ./Scripts/fetch-qpdf.sh ausführen (baut qpdf und libjpeg-turbo nach Vendor/qpdf)."
#endif

#include <qpdf/QPDF.hh>

const char *qpdfkit_version(void) {
    return QPDF::QPDFVersion().c_str();
}
