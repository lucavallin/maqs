# Data licence and attribution

The data maqs publishes is derived from the sources below. Anyone who redistributes or displays it must carry these notices. The Swift package's attribution view (Phase 4) will show the ones for the active sources.

The strings below were checked against the live sources on 2026-10-15: the VersaTiles TileJSON files for the `osm` and `elevation` tilesets, the VersaTiles tileset documentation, and Mapterhorn's `attribution.json`.

## OpenStreetMap (basemap, trails, places, curvature)

Map data © OpenStreetMap contributors, available under the [Open Database License (ODbL) 1.0](https://www.openstreetmap.org/copyright). Derived databases that maqs publishes, such as the trails, places and curvature SQLite files, are ODbL as well.

Required display text: **© OpenStreetMap contributors**, linking to https://www.openstreetmap.org/copyright.

## ESA WorldCover 2021 (landcover in the basemap)

The basemap tiles include land cover from ESA WorldCover 2021, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) (https://esa-worldcover.org/en/data-access). Attribution: © ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium.

Required display text: **CC BY 4.0 ESA WorldCover 2021**, as the VersaTiles TileJSON states it.

The basemap archives carry both credits in their metadata as this HTML string:

```html
<a href="https://www.openstreetmap.org/copyright" target="_blank">&copy; OpenStreetMap contributors</a> · <a href="http://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a> <a href="https://esa-worldcover.org/en/data-access">ESA WorldCover 2021</a>
```

## Mapterhorn (terrain)

The terrain tiles are the [Mapterhorn](https://mapterhorn.com) build, served by VersaTiles. Required display text: **© Mapterhorn**, linking to https://mapterhorn.com/attribution. The terrain archives carry it in their metadata as:

```html
<a href="https://mapterhorn.com/attribution">© Mapterhorn</a>
```

Mapterhorn combines national and regional open elevation models and credits all of them on that page; the same list is machine-readable at https://download.mapterhorn.com/attribution.json. That page and that file are the authoritative, complete list, and apps should link to the page. `attribution.json` records no extent for its sources, so the table below is not a coverage check: its rows were selected by matching each producer's territory against the bounding boxes of the launch regions (Veneto, Friuli-Venezia Giulia, Trentino-Alto Adige), and they are named as in that file:

| Source | Producer | Licence |
|---|---|---|
| TINITALY, a digital elevation model of Italy with a 10 meters cell size (Version 1.1) | Istituto Nazionale di Geofisica e Vulcanologia (INGV) | Creative Commons Namensnennung 4.0 International (CC BY 4.0) |
| LiDAR PAT 2014 integrato con voli 2018 ed il LiDAR 2011 di Campolongo | Provincia Autonoma di Trento - Ufficio Sistemi Informativi - Servizio autorizzazioni e valutazioni ambientali | CC BY 2.5 |
| Digitales Geländemodell (DGM 2,5m) | Amt für Landesplanung und Kartografie, Autonome Provinz Bozen | Creative Commons CCZero |
| DTM 5X5 - Modello digitale del terreno (ed. 2015) | Regione Lombardia | CC BY 4.0 |
| DMR - digitalni model reliefa | Slovenian Environment Agency (ARSO) | Creative Commons Attribution 4.0 |
| Digitales Geländehöhenmodell (ALS-DGM) - Höhenraster | BEV - Bundesamt für Eich- und Vermessungswesen | CC-BY-4.0 |
| Digital Elevation Modell (DEM) Austria | geoland.at, Land Kärnten. | CC-BY-4.0: Land Kärnten - data.gv.at |
| Digitales Gelände- und Oberflächenmodell Kärnten | ktn.gv.at. Land Kärnten | CC-BY-4.0: Land Kärnten - data.gv.at |
| Digitales Geländemodell 1 m (DGM) Land Salzburg | salzburg.gv.at. Land Salzburg | Creative Commons Namensnennung 4.0 International (CC BY 4.0) |
| swissALTI3D | Federal Office of Topography swisstopo | Open Government Data |
| COPERNICUS GLO-30 | DLR e.V. 2010-2014, Airbus Defence and Space GmbH 2014-2018, provided under COPERNICUS by the European Union and ESA. All rights reserved. Accessed via OpenTopography and AWS Open Data. | COPERNICUS full, free and open license |

A region added elsewhere in the world is covered by other entries of that file.

## VersaTiles

[VersaTiles](https://versatiles.org) produces and hosts the tiles. Its documentation asks only for the upstream credits above: the Shortbread schema is licensed CC0 and needs no attribution of its own.
