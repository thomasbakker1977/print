from django.db import models
from django.urls import reverse


class Hoofdstuk(models.Model):
    titel = models.CharField(max_length=200)
    volgorde = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["volgorde"]
        verbose_name_plural = "hoofdstukken"

    def __str__(self):
        return self.titel


class Sectie(models.Model):
    """Een werkdag of paragraaf uit het draaiboek, met eigen pagina in de app."""

    hoofdstuk = models.ForeignKey(Hoofdstuk, on_delete=models.CASCADE, related_name="secties")
    titel = models.CharField(max_length=300)
    slug = models.SlugField(max_length=120, unique=True)
    volgorde = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["hoofdstuk__volgorde", "volgorde"]
        verbose_name_plural = "secties"

    def __str__(self):
        return self.titel

    def get_absolute_url(self):
        return reverse("draaiboek:sectie", args=[self.slug])


class Blok(models.Model):
    """Inhoud van een sectie in de volgorde van de PDF: tekst, tabel, foto of takenlijst."""

    TEKST = "text"
    INFO = "info"
    TABEL = "table"
    AFBEELDING = "image"
    TAKEN = "tasks"
    SOORTEN = [
        (TEKST, "Tekst"),
        (INFO, "Dagkaart / gegevens"),
        (TABEL, "Tabel"),
        (AFBEELDING, "Afbeelding"),
        (TAKEN, "Takenlijst"),
    ]

    sectie = models.ForeignKey(Sectie, on_delete=models.CASCADE, related_name="blokken")
    soort = models.CharField(max_length=10, choices=SOORTEN)
    titel = models.CharField(max_length=300, blank=True)
    volgorde = models.PositiveIntegerField(default=0)
    # text: {"text": "..."} · info: {"rows": [[k, v]]} · table: {"header": [...], "rows": [[...]]}
    # image: {"file": "p06_001.jpg"} · tasks: {"columns": [...]}
    data = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["volgorde"]
        verbose_name_plural = "blokken"

    def __str__(self):
        return f"{self.sectie} · {self.get_soort_display()} {self.titel}".strip()


class Taak(models.Model):
    OPEN = "open"
    LOOPT = "loopt"
    GEREED = "gereed"
    NVT = "nvt"
    STATUSSEN = [
        (OPEN, "Open"),
        (LOOPT, "Loopt"),
        (GEREED, "Gereed"),
        (NVT, "N.v.t."),
    ]
    SYMBOLEN = {OPEN: "☐", LOOPT: "◐", GEREED: "☑", NVT: "—"}

    blok = models.ForeignKey(Blok, on_delete=models.CASCADE, related_name="taken")
    volgorde = models.PositiveIntegerField(default=0)
    nummer = models.CharField(max_length=20, blank=True)
    tijd = models.CharField(max_length=60, blank=True)
    omschrijving = models.TextField()
    # Overige kolommen uit de PDF (materiaal, notitie, bezetting, ...) als [[kolom, waarde], ...]
    details = models.JSONField(default=list, blank=True)
    wie = models.CharField(max_length=200, blank=True)
    status = models.CharField(max_length=10, choices=STATUSSEN, default=OPEN)
    opmerking = models.TextField(blank=True, help_text="Bijzonderheden voor volgend seizoen")
    bijgewerkt = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["blok__sectie__hoofdstuk__volgorde", "blok__sectie__volgorde", "blok__volgorde", "volgorde"]
        verbose_name_plural = "taken"

    def __str__(self):
        return self.omschrijving[:80]

    @property
    def symbool(self):
        return self.SYMBOLEN[self.status]

    @property
    def sectie(self):
        return self.blok.sectie
