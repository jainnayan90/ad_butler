defmodule AdButlerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AdButlerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout.

  When `current_user` is present, renders a collapsible left sidebar with navigation
  and a main content area. When nil, renders a bare wrapper for unauthenticated pages.

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user} active_nav={:campaigns} />

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :any, default: nil
  attr :active_nav, :atom, default: nil

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  def app(assigns) do
    ~H"""
    <%= if @current_user do %>
      <div class="flex h-screen overflow-hidden bg-gray-50">
        <aside
          id="app-sidebar"
          class="relative flex flex-col w-64 [&.collapsed]:w-16 transition-[width] duration-200 overflow-hidden bg-white border-r border-gray-200 shrink-0"
        >
          <div class="flex items-center h-16 px-4 border-b border-gray-200 shrink-0">
            <span class="text-lg font-bold text-gray-900 whitespace-nowrap [.collapsed_&]:hidden">
              AdButler
            </span>
            <span class="hidden text-lg font-bold text-gray-900 [.collapsed_&]:block">A</span>
          </div>

          <nav class="flex-1 px-2 py-4 space-y-1 overflow-y-auto">
            <.nav_item
              href={~p"/connections"}
              icon="hero-link"
              label="Connections"
              active={@active_nav == :connections}
            />
            <.nav_item
              href={~p"/ad-accounts"}
              icon="hero-credit-card"
              label="Ad Accounts"
              active={@active_nav == :ad_accounts}
            />
            <.nav_item
              href={~p"/campaigns"}
              icon="hero-megaphone"
              label="Campaigns"
              active={@active_nav == :campaigns}
            />
            <.nav_item
              href={~p"/ad-sets"}
              icon="hero-rectangle-stack"
              label="Ad Sets"
              active={@active_nav == :ad_sets}
            />
            <.nav_item
              href={~p"/ads"}
              icon="hero-photo"
              label="Ads"
              active={@active_nav == :ads}
            />
            <.nav_item
              href={~p"/findings"}
              icon="hero-flag"
              label="Findings"
              active={@active_nav == :findings}
            />
            <.nav_item
              href={~p"/chat"}
              icon="hero-chat-bubble-left-right"
              label="Chat"
              active={@active_nav == :chat}
            />
          </nav>

          <div class="shrink-0 px-3 py-4 border-t border-gray-200">
            <div class="flex items-center gap-3 min-w-0">
              <div class="flex items-center justify-center size-8 rounded-full bg-blue-600 text-white text-sm font-medium shrink-0">
                {String.first(@current_user.email || @current_user.name || "?")}
              </div>
              <div class="min-w-0 [.collapsed_&]:hidden">
                <p class="text-sm font-medium text-gray-900 truncate">{@current_user.email}</p>
              </div>
            </div>
            <.link
              method="delete"
              href={~p"/auth/logout"}
              class="mt-3 flex items-center gap-2 text-sm text-red-600 hover:text-red-800 whitespace-nowrap [.collapsed_&]:hidden"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Logout
            </.link>
          </div>

          <button
            class="absolute top-4 -right-3 z-10 flex items-center justify-center size-6 rounded-full bg-white border border-gray-300 shadow-sm hover:bg-gray-50"
            phx-click={JS.toggle_class("collapsed", to: "#app-sidebar")}
            aria-label="Toggle sidebar"
          >
            <.icon
              name="hero-chevron-left"
              class="size-3 text-gray-600 transition-transform [.collapsed_&]:rotate-180"
            />
          </button>
        </aside>

        <div class="flex flex-col flex-1 min-w-0 overflow-y-auto">
          <.flash_group flash={@flash} />
          <main class="flex-1 px-6 py-6">
            {@inner_content}
          </main>
        </div>
      </div>
    <% else %>
      <main class="px-4 py-20 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-2xl space-y-4">
          <.flash_group flash={@flash} />
          {@inner_content}
        </div>
      </main>
    <% end %>
    """
  end

  @doc false
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium transition-colors whitespace-nowrap",
        @active && "bg-blue-50 text-blue-700",
        !@active && "text-gray-700 hover:bg-gray-100 hover:text-gray-900"
      ]}
    >
      <.icon name={@icon} class="size-5 shrink-0" />
      <span class="[.collapsed_&]:hidden">{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
