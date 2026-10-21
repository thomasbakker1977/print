from django.urls import path

from . import views

app_name = "draaiboek"

urlpatterns = [
    path("", views.overzicht, name="overzicht"),
    path("taken/", views.taken, name="taken"),
    path("taak/<int:pk>/", views.taak_bijwerken, name="taak_bijwerken"),
    path("<slug:slug>/", views.sectie, name="sectie"),
]
