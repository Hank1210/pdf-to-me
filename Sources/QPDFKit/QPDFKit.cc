// Umsetzung der C-Schnittstelle aus QPDFKit.h mit qpdf.

#include "QPDFKit.h"

#if !__has_include(<qpdf/QPDF.hh>)
#error "qpdf fehlt. Bitte zuerst ./Scripts/fetch-qpdf.sh ausführen (baut qpdf und libjpeg-turbo nach Vendor/qpdf)."
#endif

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFAcroFormDocumentHelper.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFOutlineDocumentHelper.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/Pl_Discard.hh>

#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace {

struct Source {
    std::string bytes;   // muss leben, solange die QPDF-Instanz liest
    std::shared_ptr<QPDF> pdf;
    std::vector<QPDFPageObjectHelper> pages;
    std::unique_ptr<QPDFAcroFormDocumentHelper> forms;
    std::unique_ptr<QPDFOutlineDocumentHelper> outlines;
    std::string title;
};

struct PageSpec {
    int source;
    int index;
    int rotation;
};

struct OutlineItem {
    std::string title;
    QPDFObjectHandle destination;   // uninitialisiert = Überschrift ohne Ziel
    int count = 0;                  // Vorzeichen wie in der Quelle: > 0 aufgeklappt
    std::vector<OutlineItem> kids;
};

void copyMessage(const std::string &message, char *error, size_t length) {
    if (!error || length == 0) return;
    std::strncpy(error, message.c_str(), length - 1);
    error[length - 1] = 0;
}

QKStatus fail(const std::exception &exception, char *error, size_t length) {
    copyMessage(exception.what(), error, length);
    if (auto qpdf = dynamic_cast<const QPDFExc *>(&exception)) {
        if (qpdf->getErrorCode() == qpdf_e_password) return QK_WRONG_PASSWORD;
        if (qpdf->getErrorCode() == qpdf_e_damaged_pdf) return QK_DAMAGED;
    }
    return QK_FAILED;
}

/// Ziel eines Links: `/Dest` oder `/A << /S /GoTo /D … >>`. Uninitialisiert, wenn es kein internes Ziel ist.
QPDFObjectHandle linkDestination(QPDFObjectHandle annotation) {
    if (annotation.hasKey("/Dest")) return annotation.getKey("/Dest");
    auto action = annotation.getKey("/A");
    if (action.isDictionary() && action.getKey("/S").isNameAndEquals("/GoTo")) return action.getKey("/D");
    return {};
}

void setLinkDestination(QPDFObjectHandle annotation, QPDFObjectHandle destination) {
    annotation.removeKey("/A");
    annotation.replaceKey("/Dest", destination);
}

}  // namespace

struct QKComposer {
    std::vector<std::unique_ptr<Source>> sources;
    std::vector<PageSpec> pages;
};

const char *qpdfkit_version(void) {
    return QPDF::QPDFVersion().c_str();
}

QKComposer *qk_composer_new(void) { return new QKComposer(); }

void qk_composer_free(QKComposer *composer) { delete composer; }

QKStatus qk_add_source(QKComposer *composer, const void *bytes, size_t length, const char *password,
                       const char *title, int *index, char *error, size_t error_length) {
    try {
        auto source = std::make_unique<Source>();
        source->bytes.assign(static_cast<const char *>(bytes), length);
        source->pdf = std::make_shared<QPDF>();
        // Keine Warnungen auf die Konsole; Fehler kommen als Ausnahme.
        source->pdf->setSuppressWarnings(true);
        // Beschreibung ohne Dateinamen, damit Fehlermeldungen keine persönlichen Angaben enthalten.
        std::string description = "source " + std::to_string(composer->sources.size() + 1);
        source->pdf->processMemoryFile(description.c_str(), source->bytes.data(), source->bytes.size(), password);
        source->pages = QPDFPageDocumentHelper(*source->pdf).getAllPages();
        source->forms = std::make_unique<QPDFAcroFormDocumentHelper>(*source->pdf);
        source->outlines = std::make_unique<QPDFOutlineDocumentHelper>(*source->pdf);
        source->title = title ? title : "";
        composer->sources.push_back(std::move(source));
        *index = int(composer->sources.size()) - 1;
        return QK_OK;
    } catch (std::exception &exception) {
        return fail(exception, error, error_length);
    }
}

int qk_source_page_count(QKComposer *composer, int source) {
    if (source < 0 || size_t(source) >= composer->sources.size()) return 0;
    return int(composer->sources[size_t(source)]->pages.size());
}

void qk_add_page(QKComposer *composer, int source, int page_index, int rotation) {
    composer->pages.push_back({source, page_index, rotation});
}

QKStatus qk_write(QKComposer *composer, const char *path, const char *password, const char *creator, char *error,
                  size_t error_length) {
    try {
        auto &sources = composer->sources;
        for (auto &spec : composer->pages) {
            if (spec.source < 0 || size_t(spec.source) >= sources.size() || spec.index < 0 ||
                size_t(spec.index) >= sources[size_t(spec.source)]->pages.size()) {
                copyMessage("page reference out of range", error, error_length);
                return QK_FAILED;
            }
        }

        QPDF out;
        out.emptyPDF();
        out.setSuppressWarnings(true);
        QPDFPageDocumentHelper outPages(out);
        QPDFAcroFormDocumentHelper outForms(out);

        // 1. Seiten kopieren. (Quelle, Seitenobjekt) → erste Kopie; dorthin zeigen Links und Inhaltsverzeichnis.
        std::map<std::pair<int, QPDFObjGen>, QPDFObjectHandle> firstCopy;
        std::vector<std::pair<QPDFObjectHandle, int>> copied;   // Kopie und ihre Quelle, in Planreihenfolge
        std::set<QPDFObjGen> used;
        bool needAppearances = false;
        for (auto &spec : composer->pages) {
            auto &source = *sources[size_t(spec.source)];
            auto original = source.pages[size_t(spec.index)].getObjectHandle();
            auto copy = out.copyForeignObject(original);
            bool duplicate = !used.insert(copy.getObjGen()).second;
            if (duplicate) {
                // Eine Seite zum zweiten Mal: eigene Seite mit eigenen Anmerkungen (eine Anmerkung gehört zu genau
                // einer Seite).
                copy = QPDFPageObjectHelper(copy).shallowCopyPage().getObjectHandle();
                used.insert(copy.getObjGen());
                auto annotations = copy.getKey("/Annots");
                if (annotations.isArray()) {
                    std::vector<QPDFObjectHandle> own;
                    for (auto &annotation : annotations.aitems()) {
                        auto clone = out.makeIndirectObject(annotation.shallowCopy());
                        clone.replaceKey("/P", copy);
                        own.push_back(clone);
                    }
                    copy.replaceKey("/Annots", QPDFObjectHandle::newArray(own));
                }
            }
            QPDFPageObjectHelper page(copy);
            outPages.addPage(page, false);
            if (!duplicate) {
                // Formularfelder ins Formularverzeichnis der neuen Datei übernehmen (bei Namensgleichheit benennt
                // qpdf um).
                outForms.fixCopiedAnnotations(copy, original, *source.forms);
                if (source.forms->getNeedAppearances()) needAppearances = true;
            }
            if (spec.rotation % 360 != 0) page.rotatePage(spec.rotation, true);
            firstCopy.emplace(std::make_pair(spec.source, original.getObjGen()), copy);
            copied.emplace_back(copy, spec.source);
        }
        if (needAppearances) outForms.setNeedAppearances(true);

        // 2. Interne Links: benannte Ziele über die Quelle auflösen; Links auf Seiten außerhalb des Ergebnisses
        //    entfernen (der Text bleibt).
        std::set<QPDFObjGen> inResult;
        for (auto &entry : copied) inResult.insert(entry.first.getObjGen());
        for (auto &entry : copied) {
            auto page = entry.first;
            auto &source = *sources[size_t(entry.second)];
            auto annotations = page.getKey("/Annots");
            if (!annotations.isArray()) continue;
            std::vector<QPDFObjectHandle> keep;
            for (auto &annotation : annotations.aitems()) {
                if (!annotation.getKey("/Subtype").isNameAndEquals("/Link")) {
                    keep.push_back(annotation);
                    continue;
                }
                auto destination = linkDestination(annotation);
                if (!destination) {
                    keep.push_back(annotation);   // externer Link oder andere Aktion
                    continue;
                }
                if (destination.isName() || destination.isString()) {
                    auto resolved = source.outlines->resolveNamedDest(destination);
                    auto target = resolved.isArray() && resolved.getArrayNItems() > 0
                                      ? firstCopy.find({entry.second, resolved.getArrayItem(0).getObjGen()})
                                      : firstCopy.end();
                    if (target == firstCopy.end()) continue;   // Ziel nicht im Ergebnis
                    auto items = resolved.getArrayAsVector();
                    items[0] = target->second;
                    setLinkDestination(annotation, QPDFObjectHandle::newArray(items));
                    keep.push_back(annotation);
                    continue;
                }
                if (destination.isArray() && destination.getArrayNItems() > 0 &&
                    destination.getArrayItem(0).isIndirect() &&
                    !inResult.count(destination.getArrayItem(0).getObjGen())) {
                    continue;   // Zielseite nicht im Ergebnis
                }
                keep.push_back(annotation);
            }
            page.replaceKey("/Annots", QPDFObjectHandle::newArray(keep));
        }

        // 3. Inhaltsverzeichnis aus den Quellen neu aufbauen, nur mit Zielen im Ergebnis.
        std::function<bool(QPDFOutlineObjectHelper &, int, OutlineItem &)> collect =
            [&](QPDFOutlineObjectHelper &outline, int source, OutlineItem &item) {
                item.title = outline.getTitle();
                item.count = outline.getCount();
                auto destination = outline.getDest();   // löst benannte Ziele auf
                if (destination.isArray() && destination.getArrayNItems() > 0) {
                    auto target = firstCopy.find({source, destination.getArrayItem(0).getObjGen()});
                    if (target != firstCopy.end()) {
                        auto items = destination.getArrayAsVector();
                        items[0] = target->second;
                        item.destination = QPDFObjectHandle::newArray(items);
                    }
                }
                for (auto &kid : outline.getKids()) {
                    OutlineItem child;
                    if (collect(kid, source, child)) item.kids.push_back(child);
                }
                return item.destination.isInitialized() || !item.kids.empty();
            };
        std::vector<OutlineItem> groups;
        std::set<int> seen;
        for (auto &spec : composer->pages) {
            if (!seen.insert(spec.source).second) continue;
            auto &source = *sources[size_t(spec.source)];
            OutlineItem group;
            group.title = source.title;
            for (auto &top : source.outlines->getTopLevelOutlines()) {
                OutlineItem item;
                if (collect(top, spec.source, item)) group.kids.push_back(item);
            }
            if (group.kids.empty()) continue;
            // Die Gruppe zeigt auf die erste Seite dieser Quelle im Ergebnis, oben links.
            for (auto &entry : copied) {
                if (entry.second == spec.source) {
                    group.destination = QPDFObjectHandle::newArray(
                        {entry.first, QPDFObjectHandle::newName("/Fit")});
                    break;
                }
            }
            group.count = int(group.kids.size());
            groups.push_back(group);
        }
        std::function<QPDFObjectHandle(const OutlineItem &, QPDFObjectHandle)> make =
            [&](const OutlineItem &item, QPDFObjectHandle parent) {
                auto dictionary = out.makeIndirectObject(QPDFObjectHandle::newDictionary());
                dictionary.replaceKey("/Title", QPDFObjectHandle::newUnicodeString(item.title));
                dictionary.replaceKey("/Parent", parent);
                if (item.destination.isInitialized()) dictionary.replaceKey("/Dest", item.destination);
                QPDFObjectHandle previous;
                for (size_t index = 0; index < item.kids.size(); ++index) {
                    auto kid = make(item.kids[index], dictionary);
                    if (index == 0) dictionary.replaceKey("/First", kid);
                    if (previous.isInitialized()) {
                        previous.replaceKey("/Next", kid);
                        kid.replaceKey("/Prev", previous);
                    }
                    previous = kid;
                }
                if (previous.isInitialized()) {
                    dictionary.replaceKey("/Last", previous);
                    int visible = int(item.kids.size());
                    dictionary.replaceKey("/Count", QPDFObjectHandle::newInteger(item.count > 0 ? visible : -visible));
                }
                return dictionary;
            };
        if (!groups.empty()) {
            OutlineItem root;
            root.count = 1;
            // Eine Quelle: ihre Einträge direkt; mehrere: je ein Eintrag mit dem Dateinamen.
            root.kids = groups.size() == 1 ? groups[0].kids : groups;
            auto outlines = make(root, QPDFObjectHandle::newNull());
            outlines.removeKey("/Parent");
            outlines.removeKey("/Title");
            outlines.replaceKey("/Type", QPDFObjectHandle::newName("/Outlines"));
            out.getRoot().replaceKey("/Outlines", outlines);
        }

        // 4. Metadaten der ersten Quelle, Ersteller „PDF to me“.
        auto info = out.makeIndirectObject(QPDFObjectHandle::newDictionary());
        if (!composer->pages.empty()) {
            auto sourceInfo = sources[size_t(composer->pages.front().source)]->pdf->getTrailer().getKey("/Info");
            if (sourceInfo.isDictionary()) {
                for (auto key : {"/Title", "/Author", "/Subject", "/Keywords"}) {
                    auto value = sourceInfo.getKey(key);
                    if (value.isString()) info.replaceKey(key, QPDFObjectHandle::newString(value.getStringValue()));
                }
            }
        }
        if (creator) info.replaceKey("/Creator", QPDFObjectHandle::newUnicodeString(creator));
        out.getTrailer().replaceKey("/Info", info);

        // 5. Schreiben, auf Wunsch mit Passwort (AES-256, alle Rechte für den Besitzer des Passworts).
        QPDFWriter writer(out, path);
        if (password && *password) {
            writer.setR6EncryptionParameters(password, password, true, true, true, true, true, true, qpdf_r3p_full,
                                             true);
        }
        writer.write();
        return QK_OK;
    } catch (std::exception &exception) {
        return fail(exception, error, error_length);
    }
}

QKStatus qk_check(const char *path, const char *password, int *page_count, int *warnings, char *error,
                  size_t error_length) {
    try {
        QPDF pdf;
        pdf.setSuppressWarnings(true);
        pdf.processFile(path, password);
        *page_count = int(QPDFPageDocumentHelper(pdf).getAllPages().size());
        // Alles einmal ins Leere schreiben: liest jedes Objekt und dekodiert die Datenströme (wie qpdf --check).
        Pl_Discard discard;
        QPDFWriter writer(pdf);
        writer.setOutputPipeline(&discard);
        writer.setDecodeLevel(qpdf_dl_generalized);
        writer.write();
        *warnings = int(pdf.getWarnings().size());
        return QK_OK;
    } catch (std::exception &exception) {
        return fail(exception, error, error_length);
    }
}
