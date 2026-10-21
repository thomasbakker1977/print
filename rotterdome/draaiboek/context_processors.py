from .models import Hoofdstuk


def navigatie(request):
    return {"nav_hoofdstukken": Hoofdstuk.objects.prefetch_related("secties")}
