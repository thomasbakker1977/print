// Slaat wijzigingen aan een taak direct op (status meteen, tekstvelden na even wachten).
document.documentElement.classList.add("js");

function slaOp(form) {
  const melding = form.querySelector(".melding");
  melding.classList.remove("fout");
  melding.textContent = "Opslaan…";
  fetch(form.action, {
    method: "POST",
    body: new FormData(form),
    headers: { "X-Requested-With": "fetch" },
  })
    .then((r) => {
      if (!r.ok) throw new Error(r.status);
      return r.json();
    })
    .then((data) => {
      const taak = form.closest(".taak");
      taak.className = taak.className.replace(/status-\w+/, "status-" + data.status);
      melding.textContent = "Opgeslagen ✓";
      setTimeout(() => { if (melding.textContent === "Opgeslagen ✓") melding.textContent = ""; }, 2000);
      werkVoortgangBij(data.telling);
    })
    .catch(() => {
      melding.classList.add("fout");
      melding.textContent = "Opslaan mislukt — probeer opnieuw";
    });
}

// De voortgangsbalk bovenaan een sectiepagina bijwerken (niet op de takenlijst, die is sectie-overstijgend)
function werkVoortgangBij(telling) {
  const balk = document.querySelector(".inhoud > .kaart [data-voortgang]");
  if (!balk || document.querySelector(".filters")) return;
  for (const status of ["open", "loopt", "gereed", "nvt"]) {
    balk.querySelector(".balk ." + status).style.flexGrow = telling[status];
    balk.querySelector('[data-n="' + status + '"]').textContent = telling[status];
  }
  balk.querySelector("[data-procent]").textContent = telling.procent + "%";
}

document.querySelectorAll("form[data-taak-form]").forEach((form) => {
  let timer;
  form.addEventListener("change", (e) => {
    if (e.target.name === "status") slaOp(form);
  });
  form.addEventListener("input", (e) => {
    if (e.target.name !== "wie" && e.target.name !== "opmerking") return;
    clearTimeout(timer);
    timer = setTimeout(() => slaOp(form), 700);
  });
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    slaOp(form);
  });
});

// Opmerkingvelden laten meegroeien met de tekst
document.querySelectorAll(".taak-velden textarea").forEach((ta) => {
  const pas = () => { ta.style.height = "auto"; ta.style.height = ta.scrollHeight + 2 + "px"; };
  ta.addEventListener("input", pas);
  pas();
});

// Bewerkscherm: rijen of taken toevoegen, verwijderen markeren en waarschuwen bij niet-opgeslagen wijzigingen
function laatGroeien(ta) {
  ta.style.height = "auto";
  ta.style.height = ta.scrollHeight + 2 + "px";
}

const bewerkForm = document.querySelector("form[data-bewerk-form]");
if (bewerkForm) {
  let gewijzigd = false;
  bewerkForm.addEventListener("input", () => { gewijzigd = true; });
  bewerkForm.addEventListener("submit", () => { gewijzigd = false; });
  window.addEventListener("beforeunload", (e) => {
    if (gewijzigd) e.preventDefault();
  });

  bewerkForm.querySelectorAll("textarea[data-groei]").forEach(laatGroeien);
  bewerkForm.addEventListener("input", (e) => {
    if (e.target.matches("textarea[data-groei]")) laatGroeien(e.target);
  });

  bewerkForm.addEventListener("change", (e) => {
    if (!e.target.matches("[data-verwijder]")) return;
    const doel = e.target.closest("tr, .bewerk-taak, [data-blok]");
    doel.classList.toggle("wordt-verwijderd", e.target.checked);
    gewijzigd = true;
  });

  bewerkForm.querySelectorAll("[data-voeg-toe]").forEach((knop) => {
    knop.addEventListener("click", () => {
      const blok = knop.closest("[data-blok]");
      const rijen = blok.querySelector("[data-rijen]");
      const sjabloon = blok.querySelector("template[data-nieuwe-rij]");
      const n = Number(rijen.dataset.volgende);
      rijen.dataset.volgende = n + 1;
      const html = sjabloon.innerHTML.replaceAll("__N__", String(n));
      rijen.insertAdjacentHTML("beforeend", html);
      const nieuw = rijen.lastElementChild;
      nieuw.querySelectorAll("textarea[data-groei]").forEach(laatGroeien);
      const eerste = nieuw.querySelector("textarea, input[type=text]");
      if (eerste) eerste.focus();
      gewijzigd = true;
    });
  });
}
