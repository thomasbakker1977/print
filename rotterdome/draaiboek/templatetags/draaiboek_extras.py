from django import template
from django.utils.html import format_html, format_html_join
from django.utils.safestring import mark_safe

register = template.Library()


@register.filter
def tekst_html(tekst):
    """Zet tekstregels uit de PDF om naar alinea's en opsommingen.

    Regels die met • beginnen zijn opsommingspunten; andere regels zijn het vervolg
    van de vorige regel, tenzij die met een leesteken eindigde.
    """
    stukken = []  # [("li" | "p", tekst)]
    for regel in (tekst or "").splitlines():
        regel = regel.strip()
        if not regel:
            continue
        if regel.startswith("•"):
            stukken.append(["li", regel.lstrip("• ").strip()])
        elif stukken and stukken[-1][1][-1:] not in ".:!?)":
            stukken[-1][1] += " " + regel
        else:
            stukken.append(["p", regel])

    html, lijst = [], []
    for soort, inhoud in stukken + [["einde", ""]]:
        if soort == "li":
            lijst.append((inhoud,))
            continue
        if lijst:
            html.append(format_html("<ul>{}</ul>", format_html_join("", "<li>{}</li>", lijst)))
            lijst = []
        if soort == "p":
            html.append(format_html("<p>{}</p>", inhoud))
    return mark_safe("".join(html))


@register.filter
def kolom_klasse(kolom):
    """CSS-klasse voor een detailkolom, zodat notities anders ogen dan materiaal."""
    kolom = kolom.lower()
    if "notitie" in kolom or "aandacht" in kolom:
        return "notitie"
    return "detail"
