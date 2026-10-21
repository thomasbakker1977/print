from django.db.models import Count, Prefetch, Q
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils.http import url_has_allowed_host_and_scheme
from django.views.decorators.http import require_POST

from .models import Blok, Hoofdstuk, Sectie, Taak


def _telling(qs):
    """Aantal taken per status, plus totaal en percentage afgerond (gereed + n.v.t.)."""
    per_status = dict(qs.values_list("status").annotate(n=Count("id")))
    totaal = sum(per_status.values())
    klaar = per_status.get(Taak.GEREED, 0) + per_status.get(Taak.NVT, 0)
    return {
        "totaal": totaal,
        "open": per_status.get(Taak.OPEN, 0),
        "loopt": per_status.get(Taak.LOOPT, 0),
        "gereed": per_status.get(Taak.GEREED, 0),
        "nvt": per_status.get(Taak.NVT, 0),
        "procent": round(100 * klaar / totaal) if totaal else 0,
    }


def _wie_suggesties():
    return Taak.objects.exclude(wie="").values_list("wie", flat=True).distinct().order_by("wie")


def overzicht(request):
    hoofdstukken = []
    for hoofdstuk in Hoofdstuk.objects.prefetch_related("secties"):
        secties = [
            {"sectie": s, "telling": _telling(Taak.objects.filter(blok__sectie=s))}
            for s in hoofdstuk.secties.all()
        ]
        hoofdstukken.append({"hoofdstuk": hoofdstuk, "secties": secties})
    return render(request, "draaiboek/overzicht.html", {
        "hoofdstukken": hoofdstukken,
        "telling": _telling(Taak.objects.all()),
    })


def sectie(request, slug):
    sectie = get_object_or_404(Sectie.objects.select_related("hoofdstuk"), slug=slug)
    blokken = sectie.blokken.prefetch_related(Prefetch("taken", queryset=Taak.objects.order_by("volgorde")))
    alle = list(Sectie.objects.only("slug", "titel"))
    index = next(i for i, s in enumerate(alle) if s.pk == sectie.pk)
    return render(request, "draaiboek/sectie.html", {
        "sectie": sectie,
        "blokken": blokken,
        "vorige": alle[index - 1] if index > 0 else None,
        "volgende": alle[index + 1] if index + 1 < len(alle) else None,
        "telling": _telling(Taak.objects.filter(blok__sectie=sectie)),
        "statussen": Taak.STATUSSEN,
        "wie_suggesties": _wie_suggesties(),
    })


def taken(request):
    statussen = request.GET.getlist("status") or [Taak.OPEN, Taak.LOOPT]
    wie = request.GET.get("wie", "").strip()
    zoek = request.GET.get("q", "").strip()
    sectie_slug = request.GET.get("sectie", "")

    qs = Taak.objects.select_related("blok__sectie__hoofdstuk").filter(status__in=statussen)
    if wie:
        qs = qs.filter(wie__icontains=wie)
    if zoek:
        qs = qs.filter(Q(omschrijving__icontains=zoek) | Q(opmerking__icontains=zoek)
                       | Q(details__icontains=zoek) | Q(wie__icontains=zoek))
    if sectie_slug:
        qs = qs.filter(blok__sectie__slug=sectie_slug)

    return render(request, "draaiboek/taken.html", {
        "taken": qs,
        "gekozen_statussen": statussen,
        "wie": wie,
        "zoek": zoek,
        "sectie_slug": sectie_slug,
        "secties": Sectie.objects.all(),
        "statussen": Taak.STATUSSEN,
        "wie_suggesties": _wie_suggesties(),
    })


@require_POST
def taak_bijwerken(request, pk):
    taak = get_object_or_404(Taak, pk=pk)
    status = request.POST.get("status")
    if status in dict(Taak.STATUSSEN):
        taak.status = status
    if "wie" in request.POST:
        taak.wie = request.POST["wie"].strip()[:200]
    if "opmerking" in request.POST:
        taak.opmerking = request.POST["opmerking"].strip()
    taak.save()

    if request.headers.get("x-requested-with") == "fetch":
        return JsonResponse({
            "status": taak.status,
            "symbool": taak.symbool,
            "telling": _telling(Taak.objects.filter(blok__sectie=taak.blok.sectie)),
        })
    terug = request.POST.get("next")
    if terug and url_has_allowed_host_and_scheme(terug, allowed_hosts={request.get_host()}):
        return redirect(f"{terug}#taak-{taak.pk}")
    return redirect(taak.blok.sectie)
