import os

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils.text import slugify

from draaiboek.models import (
    KOLOMMEN_NUMMER,
    KOLOMMEN_OMSCHRIJVING,
    KOLOMMEN_OVERSLAAN,
    KOLOMMEN_TIJD,
    KOLOMMEN_WIE,
    Blok,
    Hoofdstuk,
    Sectie,
    Taak,
)
from draaiboek.pdf_import import parse_pdf


class Command(BaseCommand):
    help = "Importeert het draaiboek-PDF in de database (vervangt de bestaande inhoud)."

    def add_arguments(self, parser):
        parser.add_argument("pdf", help="Pad naar het draaiboek-PDF")
        parser.add_argument(
            "--behoud-voortgang",
            action="store_true",
            help="Status, wie en opmerking van taken met dezelfde omschrijving overnemen uit de huidige database",
        )

    def handle(self, pdf, behoud_voortgang, **options):
        if not os.path.exists(pdf):
            raise CommandError(f"Bestand niet gevonden: {pdf}")
        try:
            chapters = parse_pdf(pdf, os.path.join(settings.MEDIA_ROOT, "draaiboek"))
        except ImportError:
            raise CommandError("pdfplumber ontbreekt: pip install -r requirements.txt")

        voortgang = {}
        if behoud_voortgang:
            for t in Taak.objects.select_related("blok__sectie"):
                voortgang[(t.blok.sectie.titel, t.omschrijving)] = (t.status, t.wie, t.opmerking)

        with transaction.atomic():
            Hoofdstuk.objects.all().delete()
            slugs = set()
            n_taken = 0
            for h_nr, chapter in enumerate(chapters):
                hoofdstuk = Hoofdstuk.objects.create(titel=chapter["title"], volgorde=h_nr)
                for s_nr, section in enumerate(chapter["sections"]):
                    slug = base = slugify(section["title"])[:100] or "sectie"
                    i = 2
                    while slug in slugs:
                        slug = f"{base}-{i}"
                        i += 1
                    slugs.add(slug)
                    sectie = Sectie.objects.create(
                        hoofdstuk=hoofdstuk, titel=section["title"], slug=slug, volgorde=s_nr
                    )
                    for b_nr, block in enumerate(section["blocks"]):
                        data = {k: v for k, v in block.items() if k not in ("kind", "title", "tasks")}
                        blok = Blok.objects.create(
                            sectie=sectie, soort=block["kind"], titel=block["title"], volgorde=b_nr, data=data
                        )
                        for t_nr, task in enumerate(block.get("tasks", [])):
                            taak = self.maak_taak(blok, t_nr, task)
                            if (sectie.titel, taak.omschrijving) in voortgang:
                                taak.status, taak.wie, taak.opmerking = voortgang[(sectie.titel, taak.omschrijving)]
                            taak.save()
                            n_taken += 1

        self.stdout.write(self.style.SUCCESS(
            f"{Hoofdstuk.objects.count()} hoofdstukken, {Sectie.objects.count()} secties "
            f"en {n_taken} taken geïmporteerd."
        ))

    def maak_taak(self, blok, volgorde, task):
        taak = Taak(blok=blok, volgorde=volgorde, status=task["status"])
        details = []
        for kolom, waarde in task["fields"]:
            if kolom in KOLOMMEN_OMSCHRIJVING:
                taak.omschrijving = waarde
            elif kolom in KOLOMMEN_NUMMER:
                taak.nummer = waarde
            elif kolom in KOLOMMEN_TIJD:
                taak.tijd = waarde
            elif kolom in KOLOMMEN_WIE:
                taak.wie = waarde
            elif kolom not in KOLOMMEN_OVERSLAAN:
                details.append([kolom, waarde])
        taak.details = details
        return taak
