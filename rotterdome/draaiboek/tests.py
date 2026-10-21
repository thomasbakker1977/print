from django.test import TestCase
from django.urls import reverse

from .models import Blok, Hoofdstuk, Sectie, Taak
from .templatetags.draaiboek_extras import tekst_html


class DraaiboekTests(TestCase):
    def setUp(self):
        hoofdstuk = Hoofdstuk.objects.create(titel="3. Opbouw per dag", volgorde=1)
        self.sectie = Sectie.objects.create(hoofdstuk=hoofdstuk, titel="Vrijdag 30 oktober", slug="vrijdag-30-oktober")
        blok = Blok.objects.create(sectie=self.sectie, soort=Blok.TAKEN, data={"columns": ["#", "Taak", "Wie"]})
        self.taak = Taak.objects.create(
            blok=blok, nummer="1", omschrijving="Halhuid uitpakken", wie="Thomas",
            details=[["Aandachtspunt / notitie", "Vóór de eerste shift"]],
        )
        Taak.objects.create(blok=blok, nummer="2", omschrijving="Lampen controleren", status=Taak.GEREED)

    def test_overzicht_toont_voortgang(self):
        response = self.client.get(reverse("draaiboek:overzicht"))
        self.assertContains(response, "Vrijdag 30 oktober")
        self.assertContains(response, "50%")

    def test_sectiepagina_toont_taken(self):
        response = self.client.get(self.sectie.get_absolute_url())
        self.assertContains(response, "Halhuid uitpakken")
        self.assertContains(response, "Vóór de eerste shift")

    def test_takenlijst_filtert_standaard_op_open_en_loopt(self):
        response = self.client.get(reverse("draaiboek:taken"))
        self.assertContains(response, "Halhuid uitpakken")
        self.assertNotContains(response, "Lampen controleren")

    def test_takenlijst_filter_op_wie(self):
        response = self.client.get(reverse("draaiboek:taken"), {"wie": "jordy"})
        self.assertNotContains(response, "Halhuid uitpakken")

    def test_taak_bijwerken_via_fetch(self):
        response = self.client.post(
            reverse("draaiboek:taak_bijwerken", args=[self.taak.pk]),
            {"status": "gereed", "wie": "Jordy", "opmerking": "Met 25 personen"},
            headers={"X-Requested-With": "fetch"},
        )
        self.assertEqual(response.json()["telling"]["gereed"], 2)
        self.taak.refresh_from_db()
        self.assertEqual((self.taak.status, self.taak.wie, self.taak.opmerking), ("gereed", "Jordy", "Met 25 personen"))

    def test_taak_bijwerken_zonder_javascript_stuurt_terug(self):
        response = self.client.post(
            reverse("draaiboek:taak_bijwerken", args=[self.taak.pk]),
            {"status": "loopt", "next": "https://example.com/"},
        )
        self.assertRedirects(response, self.sectie.get_absolute_url())

    def test_onbekende_status_wordt_genegeerd(self):
        self.client.post(reverse("draaiboek:taak_bijwerken", args=[self.taak.pk]), {"status": "kapot"})
        self.taak.refresh_from_db()
        self.assertEqual(self.taak.status, Taak.OPEN)


class BewerkenTests(TestCase):
    def setUp(self):
        hoofdstuk = Hoofdstuk.objects.create(titel="1. Kernplanning")
        self.sectie = Sectie.objects.create(hoofdstuk=hoofdstuk, titel="1.1 Tijdlijn", slug="tijdlijn")
        self.tekst = Blok.objects.create(sectie=self.sectie, soort=Blok.TEKST, volgorde=0, data={"text": "Oud"})
        self.tabel = Blok.objects.create(sectie=self.sectie, soort=Blok.TABEL, volgorde=1, data={
            "header": ["Datum", "Wat"], "rows": [["wo 28 okt", "Heftruck"], ["vr 30 okt", "Opbouw"]],
        })
        self.taken = Blok.objects.create(sectie=self.sectie, soort=Blok.TAKEN, volgorde=2,
                                         data={"columns": ["#", "Taak", "Notitie", "Wie"]})
        self.taak = Taak.objects.create(blok=self.taken, nummer="1", omschrijving="Lampen tellen",
                                        details=[["Notitie", "96 stuks"]], status=Taak.GEREED, wie="Thomas")
        self.url = reverse("draaiboek:sectie_bewerken", args=["tijdlijn"])

    def post(self, **extra):
        data = {
            "sectie-titel": "1.1 Tijdlijn 2026",
            f"blok-{self.tekst.pk}-text": "Nieuw\r\n• punt",
            f"blok-{self.tabel.pk}-h0": "Datum",
            f"blok-{self.tabel.pk}-h1": "Activiteit",
            f"blok-{self.tabel.pk}-r0-c0": "wo 28 okt",
            f"blok-{self.tabel.pk}-r0-c1": "Heftruck geleverd",
            f"blok-{self.tabel.pk}-r1-c0": "vr 30 okt",
            f"blok-{self.tabel.pk}-r1-c1": "Opbouw",
            f"taak-{self.taak.pk}-nummer": "1",
            f"taak-{self.taak.pk}-omschrijving": "Lampen tellen en testen",
            f"taak-{self.taak.pk}-d0": "96 stuks, 3 kapot",
        }
        data.update(extra)
        return self.client.post(self.url, data)

    def test_bewerkpagina_laadt(self):
        response = self.client.get(self.url)
        self.assertContains(response, "Heftruck")
        self.assertContains(response, "Lampen tellen")

    def test_tekst_tabel_en_taak_opslaan(self):
        response = self.post()
        self.assertRedirects(response, "/tijdlijn/")
        self.sectie.refresh_from_db()
        self.tekst.refresh_from_db()
        self.tabel.refresh_from_db()
        self.taak.refresh_from_db()
        self.assertEqual(self.sectie.titel, "1.1 Tijdlijn 2026")
        self.assertEqual(self.tekst.data["text"], "Nieuw\n• punt")
        self.assertEqual(self.tabel.data["header"], ["Datum", "Activiteit"])
        self.assertEqual(self.tabel.data["rows"][0], ["wo 28 okt", "Heftruck geleverd"])
        self.assertEqual(self.taak.omschrijving, "Lampen tellen en testen")
        self.assertEqual(self.taak.details, [["Notitie", "96 stuks, 3 kapot"]])
        # Voortgang blijft staan
        self.assertEqual((self.taak.status, self.taak.wie), (Taak.GEREED, "Thomas"))

    def test_rij_toevoegen_en_verwijderen(self):
        self.post(**{
            f"blok-{self.tabel.pk}-r0-del": "on",
            f"blok-{self.tabel.pk}-r2-c0": "do 5 nov",
            f"blok-{self.tabel.pk}-r2-c1": "Restpunten",
        })
        self.tabel.refresh_from_db()
        self.assertEqual(self.tabel.data["rows"], [["vr 30 okt", "Opbouw"], ["do 5 nov", "Restpunten"]])

    def test_taak_toevoegen_en_verwijderen(self):
        self.post(**{
            f"taak-{self.taak.pk}-del": "on",
            f"blok-{self.taken.pk}-dlabel": "Notitie",
            f"blok-{self.taken.pk}-nieuw0-nummer": "2",
            f"blok-{self.taken.pk}-nieuw0-omschrijving": "Brandblussers ophalen",
            f"blok-{self.taken.pk}-nieuw0-wie": "Mark",
            f"blok-{self.taken.pk}-nieuw0-d0": "Garage",
            f"blok-{self.taken.pk}-nieuw1-omschrijving": "",
        })
        taken = list(self.taken.taken.all())
        self.assertEqual(len(taken), 1)
        self.assertEqual((taken[0].nummer, taken[0].omschrijving, taken[0].wie), ("2", "Brandblussers ophalen", "Mark"))
        self.assertEqual(taken[0].details, [["Notitie", "Garage"]])

    def test_blok_verwijderen(self):
        self.post(**{f"blok-{self.tekst.pk}-del": "on"})
        self.assertFalse(Blok.objects.filter(pk=self.tekst.pk).exists())


class TekstHtmlTests(TestCase):
    def test_opsomming_en_doorlopende_regels(self):
        html = tekst_html("Inleiding loopt\ndoor op de volgende regel.\n• Punt een\n• Punt twee")
        self.assertEqual(
            html, "<p>Inleiding loopt door op de volgende regel.</p><ul><li>Punt een</li><li>Punt twee</li></ul>"
        )

    def test_lege_regel_begint_nieuwe_alinea(self):
        self.assertEqual(tekst_html("Eerste alinea\n\nTweede alinea"), "<p>Eerste alinea</p><p>Tweede alinea</p>")
