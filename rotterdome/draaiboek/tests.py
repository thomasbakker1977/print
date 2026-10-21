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


class TekstHtmlTests(TestCase):
    def test_opsomming_en_doorlopende_regels(self):
        html = tekst_html("Inleiding loopt\ndoor op de volgende regel.\n• Punt een\n• Punt twee")
        self.assertEqual(
            html, "<p>Inleiding loopt door op de volgende regel.</p><ul><li>Punt een</li><li>Punt twee</li></ul>"
        )
