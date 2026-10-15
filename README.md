# Orchestrateur de drones — simulation feu de forêt (Godot 4.7)

Simulation 3D d'une flotte de 5 drones (2 de surveillance, 3 d'action) dans un monde procédural
(ville + forêt + lac). Les décisions de mission sont prises par des **règles d'automatisation
modifiables**, en JSON, éditables pendant la simulation.

## Importer le projet

1. Ouvrir Godot 4.7.x → **Importer** → sélectionner le fichier `.zip` (ou `project.godot` après extraction).
2. Laisser Godot importer (quelques secondes), puis **F5** pour lancer.

Le monde est généré par code ; le rendu réaliste utilise des **textures photo et un ciel HDRI
libres de droits (CC0, Poly Haven)** rangés dans `assets/` (≈ 60 Mo, voir `assets/CREDITS.md`).
S'ils manquent : `python tools/download_assets.py`, puis ouvrir le projet dans Godot (import automatique).

## Commandes

| Touche | Action |
|---|---|
| Clic gauche maintenu + souris | Regarder (Maj + clic gauche : allumer un feu) |
| ZQSD (AZERTY) / WASD | Se déplacer · A / E : descendre / monter · Maj : accélérer |
| Molette · Ctrl + molette | Zoom (distance de suivi, champ de vision en FPV) · vitesse de déplacement |
| Clic molette maintenu | Faire glisser la vue (caméra libre) |
| 1 à 5 · 0 | Suivre SURV-1 / SURV-2 / ACT-1 / ACT-2 / ACT-3 · caméra libre |
| V | Changer de vue : Orbite → FPV → 2e personne → Suivi intelligent |
| Panneau CAMÉRA (à droite) | Choix du drone suivi (ACT-1, ACT-2, libre) et du mode de vue |
| F | Départ de feu aléatoire |
| Maj + clic gauche | Allumer un feu à l'endroit visé |
| ← / → · ↑ / ↓ | Direction · force du vent |
| H · J | Pluie on/off · Neige on/off |
| L | Étiquettes 3D des drones et camions on/off |
| Panneau MÉTÉO (à droite) | Boutons pluie / neige (durée réglable), curseurs vitesse et direction du vent, préréglages Calme / Brise / Vent fort / Tempête |
| Espace · + / - | Pause · vitesse de simulation (x0.5 à x8) |
| Tab | Éditeur de règles (Échap pour fermer) |
| N | Nouvelle carte (graine aléatoire) |
| F1 | Masquer l'aide |

## Architecture

```
scripts/
  main.gd                      assemble le monde, les drones et les systèmes
  autoload/event_bus.gd        bus d'événements global (signaux)
  autoload/game_state.gd       config, météo, références partagées
  world/terrain.gd             terrain procédural (bruit), lac, zones
  world/city.gd                ville procédurale (rues, immeubles, parcs)
  world/forest.gd              forêt + simulation d'incendie (automate cellulaire)
  world/road_network.gd        graphe routier : rues, route d'accès, pistes forestières (DFCI)
  world/city_life.gd           circulation automobile + piétons
  firefighters/fire_station.gd caserne : bâtiment, engagement des camions
  firefighters/fire_truck.gd   fourgon pompe-tonne (citerne, équipage, lances)
  firefighters/firefighter.gd  pompier (marche, course, attaque à la lance)
  drones/drone.gd              machine à états + vol de chaque drone
  orchestration/orchestrator.gd      moteur de règles (déclencheur → conditions → actions)
  orchestration/scenario_director.gd automatisations de la carte (chronologie)
  orchestration/external_bridge.gd   pont WebSocket vers n8n / Python
  ui/hud.gd                    supervision + éditeur de règles
  camera/free_camera.gd        caméra libre / suivi
  render/atmosphere.gd         ciel HDRI, soleil, illumination globale, brouillard, transitions météo
  render/look.gd               bibliothèque de matériaux PBR (textures assets/)
  render/vegetation.gd         modèles de pins et de feuillus, matériau de feuillage
  render/models.gd             voiture, pièces de personnage
  render/shaders/*.gdshader    sol, eau, feuillage, façades, chaussée, flammes, fumée
data/
  config.json                  paramètres (graine, drones, feu, vent, pont)
  rules.json                   règles par défaut
  scenarios/feu_de_foret.json  scénario de démonstration
  scenarios/vide.json          bac à sable sans événement
tools/bridge_server.py         serveur pont (logique Python ou webhook n8n)
tools/download_assets.py       télécharge les textures / le ciel CC0 (Poly Haven)
tools/compute_sun.gd           calcule la direction du soleil du ciel HDRI -> assets/sky/sun.json
```

Principe : les drones **n'exécutent que des commandes** et **publient des événements**.
L'orchestrateur écoute les événements et décide via les règles. Changer le comportement
de la flotte = changer les règles, sans toucher au code.

## Écrire des règles

```json
{
  "name": "Incendie détecté : déployer",
  "on": "fire_detected",
  "enabled": true,
  "conditions": [ { "field": "event.intensity", "op": ">=", "value": 1 } ],
  "actions": [
    { "type": "dispatch", "role": "action", "count": 2, "target": "event.position" },
    { "type": "orbit", "drone": "surveillance", "target": "event.position" }
  ]
}
```

- `"event.xxx"` lit une donnée de l'événement, `"world.xxx"` l'état du monde.
- Opérateurs : `==`, `!=`, `>`, `>=`, `<`, `<=`, `contains`. Toutes les conditions doivent être vraies.
- Sélecteurs de drones : `"all"`, `"surveillance"`, `"action"`, `"role:action"`, `"available:action"`, `"state:OBSERVE"` (par état), `"ACT-1"`, ou `"event.drone_id"`.
- Dans `log`, `{intensity}` insère une donnée de l'événement et `{world.wind_speed}` une donnée du monde.

Dans l'éditeur en jeu : **Appliquer** (immédiat), **Appliquer + sauvegarder** (`user://rules.json`,
rechargé aux lancements suivants), **Règles par défaut** (revient à `data/rules.json`).

### Événements

| Événement | Émis par | Données principales |
|---|---|---|
| `simulation_started` | monde | `seed` |
| `fire_detected` | drone de surveillance | `drone_id`, `position`, `intensity` |
| `fire_report` | surveillance (toutes les 10 s) | `position`, `intensity` |
| `fire_extinguished` | forêt | `burnt_cells`, `extinguished_cells` |
| `fire_ignited` | carte (vérité terrain) | `position` |
| `tank_empty` · `refill_done` | drone d'action | `drone_id`, `role`, `battery`, `water`, `state` |
| `fire_trucks_departed` · `fire_truck_arrived` | camion de pompiers | `unit_id`, `state`, `water`, `crew`, `crew_aboard` |
| `fire_truck_empty` · `fire_out_of_reach` | camion (citerne vide / feu hors de portée des lances) | idem |
| `fire_truck_returned` · `fire_truck_ready` | camion (rentré / citerne remplie) | idem |
| `battery_low` · `arrived_base` · `drone_ready` · `arrived` | drone | idem |
| `takeoff` | drone (fin de la mise en route au sol) | idem |
| `fire_engaged` | drone d'action arrivé sur le feu | idem + `position` |
| `fire_lost` | surveillance en orbite qui ne voit plus de feu depuis 6 s alors qu'un incendie est encore actif | idem |
| `wind_changed` | météo | `speed`, `direction_deg` |
| `rain_started` · `rain_stopped` · `snow_started` · `snow_stopped` | météo | `duration` (0 = illimitée) |
| `scenario_step` | scénario | `t`, `type` |
| tout autre nom | action `emit` | libre |

### État du monde (`world.xxx`)

`time`, `fire_active`, `fire_position`, `burning_cells`, `burnt_cells`, `wind_speed`,
`wind_dir_deg`, `raining`, `snowing`, `available_action_drones`, `observing_drones`, `available_fire_trucks`, `engaged_fire_trucks`.

### Actions

| Type | Paramètres |
|---|---|
| `dispatch` | `role`, `count`, `target`, `min_battery` — envoie les N drones disponibles les plus proches |
| `fight` | `drone`, `target` |
| `refill` · `return_base` · `patrol` · `hold` | `drone` |
| `orbit` | `drone`, `target` |
| `observe` | `drone`, `target` — vol stationnaire d'observation à la verticale du feu |
| `goto` | `drone`, `target` ([x, z] ou [x, y, z]), `altitude` |
| `set_drone_param` | `drone`, `param` (ex. `drop_radius`, `max_speed`), `value` |
| `set_fire_param` | `param` (`spread`, `burn_time`, `wet_duration`), `value` |
| `log` | `message`, `level` (`info`, `warn`, `rule`) |
| `ignite` | `position` (`"random"` ou coordonnées) |
| `set_wind` | `speed`, `direction_deg` (0 = vers l'Est, 90 = Sud, 180 = Ouest/ville) |
| `rain` · `stop_rain` · `snow` · `stop_snow` | `duration` |
| `dispatch_firefighters` | `count` (camions disponibles), `target`, ou `unit` (`"FPT-1"`, `"event.unit_id"`) |
| `recall_firefighters` · `refill_fire_truck` | `unit` (`"all"` par défaut) — retour caserne (remplissage automatique) |
| `emit` | `event`, `data` — déclenche un événement personnalisé (enchaîner des règles) |

Toute action accepte un paramètre optionnel **`delay`** (secondes de simulation) : elle est exécutée
après ce délai. Exemple : latence de transmission de l'alerte entre SURV-1 et les drones d'action
(`"delay": 4` sur le `dispatch` de la règle « Incendie détecté »).

### Exemples à essayer

Envoyer un seul drone si le feu est petit, sinon les deux :
```json
{ "name": "Petit feu", "on": "fire_detected",
  "conditions": [ { "field": "event.intensity", "op": "<", "value": 4 } ],
  "actions": [ { "type": "dispatch", "role": "action", "count": 1, "target": "event.position" } ] }
```
(et ajouter la condition `>= 4` à la règle existante)

Renfort automatique quand le feu grossit :
```json
{ "name": "Renfort", "on": "fire_report",
  "conditions": [ { "field": "event.intensity", "op": ">", "value": 25 },
                  { "field": "world.available_action_drones", "op": ">", "value": 0 } ],
  "actions": [ { "type": "dispatch", "role": "action", "count": 1, "target": "event.position" } ] }
```

Largage plus large par vent fort :
```json
{ "name": "Vent fort : élargir le largage", "on": "wind_changed",
  "conditions": [ { "field": "event.speed", "op": ">=", "value": 8 } ],
  "actions": [ { "type": "set_drone_param", "drone": "role:action", "param": "drop_radius", "value": 13 } ] }
```

## Scénarios (automatisations de la carte)

Une chronologie d'actions (même vocabulaire que les règles) déclenchées à `t` secondes :
```json
{ "name": "Mon scénario", "events": [
  { "t": 20, "type": "ignite", "position": [150, 40] },
  { "t": 60, "type": "set_wind", "speed": 10, "direction_deg": 180 },
  { "t": 120, "type": "rain", "duration": 30 } ] }
```
Choisir le scénario dans `data/config.json` → `"scenario"`.

## Orchestrateur externe (n8n ou Python)

1. `pip install websockets`
2. Logique Python d'exemple : `python tools/bridge_server.py`
   Avec n8n : `N8N_WEBHOOK_URL=http://localhost:5678/webhook/drones python tools/bridge_server.py`
3. Dans `data/config.json` : `"external_bridge": { "enabled": true }`
4. En jeu (Tab), décocher **Règles locales actives** pour que seul l'orchestrateur externe décide.

Workflow n8n minimal : **Webhook** (POST, reçoit `{name, data, world}`) → **Code / Switch**
(décide selon `name`) → **Respond to Webhook** renvoyant `{"actions": [ ... ]}`.
Latence acceptable pour des décisions de mission ; le vol reste géré dans Godot.

## Réglages (`data/config.json`)

- `seed` : graine de la carte (même graine = même monde, utile pour comparer des stratégies).
- `drone` : `startup_time` (mise en route des moteurs au sol avant décollage, en s), `visual_scale` (taille d'affichage des drones), `surveillance_scale` (taille du drone de surveillance relative aux drones d'action, 0.6 par défaut), `distance_boost_max` (grossissement max des drones vus de loin, 1.5), vitesse, altitudes, batterie, capacité d'eau, rayon de largage, rayon de détection…
- `fire` : `spread` (vitesse de propagation), `burn_time`, `wet_duration`.
- `wind` : vent initial.

## Export

Pour exporter le jeu, ajouter `*.json` dans *Projet → Exporter → Ressources → Filtres pour exporter
les fichiers non-ressources*, sinon les règles et scénarios ne seront pas inclus.

## Collisions

Les drones ont un encombrement physique (rayon et hauteur calculés depuis leur modèle 3D).
- **Décor** : une grille d'obstacles (relief, lac, immeubles, arbres, bâtiment de la base) donne la
  hauteur sûre en tout point. Les drones anticipent l'obstacle devant eux et montent pour le franchir ;
  une contrainte stricte les empêche d'y pénétrer (ils s'arrêtent et montent face à une façade).
- **Entre drones** : évitement anticipé + contrainte stricte : les volumes ne se chevauchent jamais
  (un drone posé reste fixe, celui qui vole s'écarte).

## Ville vivante

- **Voitures** (`city.cars`, 45 par défaut) : circulent à droite dans les rues, gardent leurs
  distances (freinage proportionnel à la vitesse), un seul véhicule à la fois dans un carrefour, et
  **se rangent sur le côté et s'arrêtent** à l'approche d'un camion de pompiers.
- **Piétons** (`city.pedestrians_per_block`, ~12 par îlot + promeneurs dans les allées des parcs) : font le tour des îlots sur les trottoirs
  dans les deux sens, ralentissent derrière un piéton plus lent, marquent des pauses.

## Caserne de pompiers

À l'est de la ville, sur la rue qui mène à la forêt : remise, tour de séchage, cour, **2 fourgons
pompe-tonne (FPT-1, FPT-2)** et **8 pompiers** (par camion : conducteur, chef d'agrès au casque rouge,
2 équipiers). Réglages : `fire_service.trucks`, `crew_per_truck`, `water_capacity`.

Déroulé d'une intervention :
1. Alerte (règle « Incendie détecté ») → l'équipage court vers son camion et monte à bord.
2. Trajet gyrophares allumés : rues → route d'accès → **pistes forestières DFCI** (bandes sans
   arbres qui quadrillent la forêt, tracé non affiché par défaut : `roads.show_forest_tracks`)
   jusqu'au point le plus proche du foyer réel. Deux camions ne se
   placent pas au même endroit.
3. Établissement : les équipiers déroulent les tuyaux (45 m max), se placent à distance de sécurité et
   **éteignent réellement les cellules visées** à la lance ; ils reculent si le feu s'approche ; le
   conducteur reste à la pompe.
4. Citerne vide → retour caserne, remplissage, et réengagement si le feu est toujours actif.
   Feu hors de portée → repli des lances et repositionnement. Feu maîtrisé → retour caserne.

Toutes ces décisions passent par les règles (`data/rules.json`), comme pour les drones. Les camions
se suivent aussi à la caméra (panneau CAMÉRA : FPT-1 / FPT-2, vue embarquée dans la cabine en FPV).

## Surveillance à deux drones

La forêt est partagée en deux bandes : **SURV-1** fait sa ronde au nord, **SURV-2** au sud.
Quand l'un détecte un feu, **il quitte sa ronde et se met en vol stationnaire à la verticale du
foyer** (55 m au-dessus du sol) et l'observe **jusqu'à ce que l'incendie soit éteint**, puis reprend
sa ronde ; l'autre continue sa ronde pendant ce temps. S'il doit rentrer recharger sa batterie, il
revient se placer au-dessus du feu une fois rechargé si personne d'autre ne l'observe. Un foyer apparu à plus de
100 m de l'incendie connu, et que personne ne surveille, est signalé comme une nouvelle détection.

## Rendu réaliste

- **Ciel et lumière** : ciel photographique HDRI qui éclaire la scène ; soleil placé à la position
  exacte du soleil de la photo (48°) ; illumination globale SDFGI, occlusion ambiante (SSAO/SSIL),
  réflexions (SSR), perspective aérienne, brouillard volumétrique, tonemapping AgX.
- **Sol** : textures photo mélangées selon la zone et la pente (prairie, sol forestier qui suit la
  densité des arbres, roche, berges sableuses, béton urbain) ; **le sol se calcine en direct** là où le
  feu passe ; paysage lointain (collines, montagnes, forêts en 3D jusqu'à 700 m).
- **Végétation** : pins à étages de branches, feuillus dans les parcs, balancement au vent,
  translucidité ; les arbres en feu se carbonisent puis ne laissent qu'un squelette noirci.
- **Ville** : 4 styles de façades photo, fenêtres vitrées réfléchissantes, vitrines, toits en gravier
  avec équipements ; chaussée avec marquage (axe, rives, passages piétons, lignes d'arrêt) ;
  voitures modélisées (berlines), piétons à taille réelle.
- **Feu** : flammes animées (sol + couronne des arbres), fumée éclairée par le soleil, colonne de fumée
  volumétrique qui projette son ombre, braises.
- **Météo** : sous la pluie les surfaces se mouillent progressivement (flaques, reflets) puis sèchent ;
  la neige s'accumule sur le sol, les toits et les arbres, puis fond.
- **Échelle des drones** : ~8,5 m d'envergure (action) et ~4,7 m (surveillance), agrandis pour rester visibles — `drone.visual_scale`,
  `surveillance_scale` ; repères au sol affichés seulement quand la caméra est loin.

Performances mesurées : ~55 images/s en vue d'ensemble (1600×900, RTX 4060 portable).
Pour une machine plus modeste : désactiver `sdfgi_enabled` / `volumetric_fog_enabled` dans
`scripts/render/atmosphere.gd`.
