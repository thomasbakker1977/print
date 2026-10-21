# Draaiboek Rotterdome — lokale webapp

Django-app om het draaiboek voor de op- en afbouw van de Rotterdome (blaashal HC Rotterdam)
bij te houden: per werkdag de dagkaart en een takenlijst die je kunt afvinken (☐ open, ◐ loopt,
☑ gereed, — n.v.t.), met de kolom "Wie" en ruimte voor bijzonderheden voor volgend seizoen.

## Installeren en starten

```bash
cd rotterdome
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python manage.py migrate
python manage.py importeer_draaiboek pad/naar/Draaiboek_Rotterdome_2026_takenlijst.pdf
python manage.py runserver
```

Open daarna http://127.0.0.1:8000/.

Voor het beheerscherm (`/admin/`) maak je eerst een account aan met
`python manage.py createsuperuser`.

## Wat zit erin

- **Overzicht**: de totale voortgang en de voortgang per hoofdstuk en per werkdag.
- **Sectiepagina's**: alles uit het PDF in dezelfde volgorde, dus dagkaart, tabellen, foto's,
  plattegrond en takenlijsten. Status, "Wie" en opmerkingen worden direct opgeslagen.
- **Takenlijst**: alle taken, te filteren op status, persoon, zoekterm en sectie. Standaard zie
  je alles wat nog open staat of loopt.
- **Printen**: de knop "Printen" (of Ctrl+P) geeft een nette afvinklijst op A4-liggend.

## Opnieuw importeren

`importeer_draaiboek` vervangt de hele inhoud van de database. Heb je een nieuwe versie van het
PDF en wil je de voortgang houden (status, wie en opmerking van taken met dezelfde omschrijving)?

```bash
python manage.py importeer_draaiboek nieuw-draaiboek.pdf --behoud-voortgang
```

## Privacy

Het draaiboek bevat namen en contactgegevens. Daarom staan het PDF, de database (`db.sqlite3`) en
de uitgepakte foto's (`media/`) in `.gitignore` en komen ze niet in deze (openbare) repository.
De app is bedoeld om lokaal te draaien met de ontwikkelserver; zet hem niet zo online.

## Tests

```bash
python manage.py test draaiboek
```
