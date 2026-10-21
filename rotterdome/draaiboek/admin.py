from django.contrib import admin

from .models import Blok, Hoofdstuk, Sectie, Taak


class SectieInline(admin.TabularInline):
    model = Sectie
    fields = ["titel", "slug", "volgorde"]
    extra = 0


@admin.register(Hoofdstuk)
class HoofdstukAdmin(admin.ModelAdmin):
    list_display = ["titel", "volgorde"]
    inlines = [SectieInline]


@admin.register(Sectie)
class SectieAdmin(admin.ModelAdmin):
    list_display = ["titel", "hoofdstuk", "volgorde"]
    list_filter = ["hoofdstuk"]
    prepopulated_fields = {"slug": ["titel"]}


@admin.register(Blok)
class BlokAdmin(admin.ModelAdmin):
    list_display = ["sectie", "soort", "titel", "volgorde"]
    list_filter = ["soort", "sectie__hoofdstuk"]


@admin.register(Taak)
class TaakAdmin(admin.ModelAdmin):
    list_display = ["omschrijving", "nummer", "wie", "status", "bijgewerkt"]
    list_editable = ["wie", "status"]
    list_filter = ["status", "blok__sectie__hoofdstuk", "blok__sectie"]
    search_fields = ["omschrijving", "wie", "opmerking"]
