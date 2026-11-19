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
#include <qpdf/Pl_Flate.hh>

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
    int overlay = -1;   // Index in QKComposer::overlays, -1 = keine
};

struct Overlay {
    std::string bytes;   // muss leben, solange die QPDF-Instanz liest
    std::shared_ptr<QPDF> pdf;
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
    std::vector<std::unique_ptr<Overlay>> overlays;
    std::vector<PageSpec> pages;
};

namespace {

/// Legt die Formular-XObject-Fassung einer Überlagerung über `page`, wie `qpdf --overlay`. Ändert nie Objekte, die
/// andere Seiten mitbenutzen könnten: Ressourcen und Inhaltsliste bekommen eigene Kopien.
void placeOverlay(QPDFObjectHandle page, QPDFObjectHandle form) {
    QPDFPageObjectHelper helper(page);
    auto resources = page.getKey("/Resources");
    resources = resources.isDictionary() ? resources.shallowCopy() : QPDFObjectHandle::newDictionary();
    auto xobjects = resources.getKey("/XObject");
    xobjects = xobjects.isDictionary() ? xobjects.shallowCopy() : QPDFObjectHandle::newDictionary();
    int suffix = 0;
    std::string name = resources.getUniqueResourceName("/Fx", suffix);
    xobjects.replaceKey(name, form);
    resources.replaceKey("/XObject", xobjects);
    page.replaceKey("/Resources", resources);

    // In den sichtbaren Ausschnitt einpassen; die eigene Drehung der Seite wird ausgeglichen
    // (invert_transformations), damit die Überlagerung so steht, wie die Seite angezeigt wird.
    auto box = helper.getCropBox(false).getArrayAsRectangle();
    std::string placed = helper.placeFormXObject(form, name, box, true, true, true);

    // Bisherigen Inhalt einklammern (q … Q), damit ein offener Grafikzustand die Überlagerung nicht verschiebt.
    auto &pdf = page.getQPDF();
    std::vector<QPDFObjectHandle> contents{pdf.newStream("q\n")};
    auto old = page.getKey("/Contents");
    if (old.isArray()) {
        for (auto &item : old.aitems()) contents.push_back(item);
    } else if (old.isStream()) {
        contents.push_back(old);
    }
    contents.push_back(pdf.newStream("\nQ\n" + placed));
    page.replaceKey("/Contents", QPDFObjectHandle::newArray(contents));
}

/// Entfernt aus den Ressourcen jeder Seite, was ihr Inhalt nicht benutzt. Seiten, deren Inhalt sich nicht lesen lässt,
/// bleiben unverändert.
void removeUnusedResources(QPDF &pdf) {
    QPDFPageDocumentHelper pages(pdf);
    pages.pushInheritedAttributesToPage();
    for (auto &page : pages.getAllPages()) {
        auto object = page.getObjectHandle();
        auto resources = object.getKey("/Resources");
        if (!resources.isDictionary()) continue;
        // Eigene Kopien von /Resources und seinen Unterverzeichnissen (/Font, /XObject, …), damit gemeinsam benutzte
        // Verzeichnisse nie für alle Seiten gekürzt werden. qpdf 12 trennt sie auch selbst; die Kopie sichert das
        // unabhängig von der qpdf-Version ab (Test: testSharedResourcesStayCompleteForEveryPage).
        resources = resources.shallowCopy();
        for (auto &key : resources.getKeys()) {
            auto category = resources.getKey(key);
            if (category.isDictionary()) resources.replaceKey(key, category.shallowCopy());
        }
        object.replaceKey("/Resources", resources);
        try {
            page.removeUnreferencedResources();
        } catch (std::exception &) {
            // Inhalt nicht lesbar: Ressourcen lieber behalten.
        }
    }
}

}  // namespace

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
        // Vom Seitenbaum geerbte Eigenschaften (/Resources, /MediaBox, /CropBox, /Rotate) auf jede Seite schieben.
        // Beim Kopieren wird nur die Seite selbst übernommen; ohne diesen Schritt fehlen sonst Schriften, Seitengröße
        // und Drehung. Betrifft nur diese Kopie im Speicher, nie die Datei.
        source->pdf->pushInheritedAttributesToPage();
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

QKStatus qk_add_overlay(QKComposer *composer, const void *bytes, size_t length, int *index, char *error,
                        size_t error_length) {
    try {
        auto overlay = std::make_unique<Overlay>();
        overlay->bytes.assign(static_cast<const char *>(bytes), length);
        overlay->pdf = std::make_shared<QPDF>();
        overlay->pdf->setSuppressWarnings(true);
        std::string description = "overlay " + std::to_string(composer->overlays.size() + 1);
        overlay->pdf->processMemoryFile(description.c_str(), overlay->bytes.data(), overlay->bytes.size());
        if (QPDFPageDocumentHelper(*overlay->pdf).getAllPages().empty()) {
            copyMessage("overlay has no page", error, error_length);
            return QK_FAILED;
        }
        composer->overlays.push_back(std::move(overlay));
        *index = int(composer->overlays.size()) - 1;
        return QK_OK;
    } catch (std::exception &exception) {
        return fail(exception, error, error_length);
    }
}

void qk_add_page_with_overlay(QKComposer *composer, int source, int page_index, int rotation, int overlay) {
    composer->pages.push_back({source, page_index, rotation, overlay});
}

QKStatus qk_write(QKComposer *composer, const char *path, const char *password, const char *creator, int compact,
                  char *error, size_t error_length) {
    try {
        auto &sources = composer->sources;
        for (auto &spec : composer->pages) {
            if (spec.source < 0 || size_t(spec.source) >= sources.size() || spec.index < 0 ||
                size_t(spec.index) >= sources[size_t(spec.source)]->pages.size()) {
                copyMessage("page reference out of range", error, error_length);
                return QK_FAILED;
            }
            if (spec.overlay < -1 || spec.overlay >= int(composer->overlays.size())) {
                copyMessage("overlay reference out of range", error, error_length);
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
        // Unveränderte Vorlage jeder kopierten Seite. Weitere Vorkommen derselben Seite entstehen aus ihr, nicht aus
        // der schon gedrehten oder überlagerten ersten Kopie. Die Vorlage selbst gelangt nicht in die Datei.
        std::map<QPDFObjGen, QPDFObjectHandle> pristine;
        std::map<int, QPDFObjectHandle> overlayForms;   // je Überlagerung ein Formular-XObject in der neuen Datei
        bool needAppearances = false;
        for (auto &spec : composer->pages) {
            auto &source = *sources[size_t(spec.source)];
            auto original = source.pages[size_t(spec.index)].getObjectHandle();
            auto copy = out.copyForeignObject(original);
            bool duplicate = !used.insert(copy.getObjGen()).second;
            if (!duplicate) {
                pristine.emplace(copy.getObjGen(), QPDFPageObjectHelper(copy).shallowCopyPage().getObjectHandle());
            } else {
                // Eine Seite zum zweiten Mal: eigene Seite mit eigenen Anmerkungen (eine Anmerkung gehört zu genau
                // einer Seite).
                copy = QPDFPageObjectHelper(pristine.at(copy.getObjGen())).shallowCopyPage().getObjectHandle();
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
            // Erst überlagern, dann drehen: Die Überlagerung passt zur Seite, wie die Quelle sie anzeigt, und dreht
            // sich danach mit ihr.
            if (spec.overlay >= 0) {
                auto form = overlayForms.find(spec.overlay);
                if (form == overlayForms.end()) {
                    auto overlayPage = QPDFPageDocumentHelper(*composer->overlays[size_t(spec.overlay)]->pdf)
                                           .getAllPages()
                                           .front();
                    auto foreign = overlayPage.getFormXObjectForPage(true);
                    form = overlayForms.emplace(spec.overlay, out.copyForeignObject(foreign)).first;
                }
                placeOverlay(copy, form->second);
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

        // 5. Verlustfrei verkleinern: Ressourcen, die der Inhalt einer Seite nicht benutzt, fallen weg (etwa Schriften
        //    und Bilder anderer Seiten, mit denen eine Quellseite ihre Ressourcen teilte).
        if (compact) removeUnusedResources(out);

        // 6. Schreiben, auf Wunsch mit Passwort (AES-256, alle Rechte für den Besitzer des Passworts).
        QPDFWriter writer(out, path);
        if (compact) {
            // Objekt-Streams, Flate auf höchster Stufe auch für schon komprimierte Streams. Bilder in JPEG (DCT)
            // bleiben unberührt.
            Pl_Flate::setCompressionLevel(9);
            writer.setObjectStreamMode(qpdf_o_generate);
            writer.setCompressStreams(true);
            writer.setDecodeLevel(qpdf_dl_generalized);
            writer.setRecompressFlate(true);
        }
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
