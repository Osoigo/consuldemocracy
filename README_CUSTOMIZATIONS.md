# Personalización para versión 2025-2026

## Frontend

### Encabezado

Aunque el texto y traducción proviene del **Encabezado** del **Administrador** de la **Homepage**; para poder añadir una imagen de fondo diferente según el **idioma** y para **desktop/mobile** se ha realizado los siguientes cambios:

- En `app/assets/images/custom`se ha añadido la carpeta `header` y las imágenes:
  - header_es.png
  - header_val.png
  - header_sm_es.png
  - header_sm_val.png
- En `app/custom/shared/_header.html.erb` podéis encontrar un nuevo código para `custom-header-card` donde se muestra la imagen según el idioma.
- Y en `app/assets/stylesheets/custom.scss` damos estilos para que se vea así.

#### Para recuperar el header original de Consul

Solo hace falta eliminar `app/custom/shared/_header.html.erb`. También puedes aprovechar para limpiar `app/assets/images/custom/header` y `app/assets/stylesheets/custom.scss`.

### Home: 3 tarjetas

Al igual que con el encabezado las **Tarjetas** o columnas de la **Homepage** las gestionamos desde el propio **Administrador** pero las imágenes tienen diferentes versiones según el **idioma**. Para diferenciarlos hemos utilizado las etiquetas de cada tarjeta:

- **crea**
- **elige**
- **vota**

Para ello en el código hemos hecho lo siguiente:

- En `app/assets/images/custom` se ha añadido la carpeta `columns` y las imágenes:
  - crea_es.jpg
  - crea_val.jpg
  - elige_es.jpg
  - elige_val.jpg
  - vota_es.jpg
  - vota_val.jpg
- En `app/custom/shared/` hemos creado `_cardshome.html.erb`y `_cardhome.html.erb` en vez de sustituir lo existente.
  - `app/custom/welcome/index.html.erb` llama a `cardshome`:

```bash
<%= render "shared/cardshome", cards: @cards %>
```

- `cardshome` llama a `cardhome`:

```bash
<%= render "shared/cardhome", card: card %>
```

- Y `cardhome` consulta el `card.label` para mostrar una imagen u otra.

```bash
  <%= link_to card.link_url do %>
    <% if card.label == "crea" %>
      <figure class="figure-card">
        <%= image_tag(image_path_for("columns/crea_#{locale}.jpg"), alt: card.title) %>
      </figure>
    <% elsif card.label == "elige" %>
      <figure class="figure-card">
        <%= image_tag(image_path_for("columns/elige_#{locale}.jpg"), alt: card.title) %>
      </figure>
    <% elsif card.label == "vota" %>
      <figure class="figure-card">
        <%= image_tag(image_path_for("columns/vota_#{locale}.jpg"), alt: card.title) %>
      </figure>
    <% else %>
      <figure class="figure-card">
        <% if card.image.present? %>
          <%= image_tag(card.image.variant(:large), alt: card.image.title) %>
        <% end %>
      </figure>
    <% end %>
```

#### Para recuperar las tarjetas de la homepage originales de Consul

Solo haría falta poner `"shared/cards"` en vez de `"shared/cardshome"` en `app/custom/welcome/index.html.erb`. También puedes eliminar `app/custom/shared/_cardshome.html.erb`y `app/custom/shared/_cardhome.html.erb`. Como todo lo que hay en la carpeta `app/assets/images/custom/columns`

### Presupuestos Participativos 2015/2016

Este apartado es una **página personalizada** del **Administrador** pero para incluirlo con el resto resultados de los presupuestos participativos se han hecho los siguientes cambios:

- Se ha creado `app/views/custom/budgets/_finished.html.erb` en donde al final incluimos el enlace a la página.
- El texto y el enlace son estáticos y se controlan desde cada idioma como `config/locales/custom/es/budgets.yml`.

```bash
    finished_budgets:
      2015_2016_title: "Presupuestos Participativos 2015/2016"
      2015_2016_link: "/budget-2015-2016"
```

#### Para recuperar el listado de presupuestos finalizados originales de Consul

Con eliminar `app/views/custom/budgets/_finished.html.erb` sería suficiente, aunque podemos limpiar los `.yml` también, e incluso eliminar la página personalizada.

### Apartado "Más información" con desplegables (help)

Para poder desarrollar una página de **Más información** con desplegables, a modo de faq, hemos adaptado la página de `help`.

En el **Administrador** a la hora de añadir el contenido que queremos que se muestre en **Más información** debemos marcarlo para **Mostrar en la página de ayuda** y automáticamente aparecerá en formato desplegable.

Para ello, en `app/views/custom/pages/help` hemos editado `index.html.erp` para que no muestre el menú y la parte de `_other.html.erp` para convertirlo a `accordion` de `Foundation.

#### Para recuperar el help original de Consul

Al eliminar `app/views/custom/pages/help` volvería a funcionar el original.
