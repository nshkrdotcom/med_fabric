defmodule MedFabric.ExamWeb.Layout do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Med Fabric Exam</title>
        <style>
          :root {
            --mf-bg: #f3f7f9;
            --mf-surface: #ffffff;
            --mf-surface-alt: #f7fbfc;
            --mf-border: #d4e2e8;
            --mf-ink: #0f2430;
            --mf-muted: #4b6573;
            --mf-accent: #1d6f7a;
            --mf-accent-hover: #145660;
            --mf-accent-soft: #e6f4f6;
            --mf-teal: #458f8b;
            --mf-dark: #102737;
            --mf-radius: 10px;
          }

          * { box-sizing: border-box; }

          body {
            margin: 0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Inter, sans-serif;
            color: var(--mf-ink);
            background: var(--mf-bg);
            line-height: 1.5;
            -webkit-font-smoothing: antialiased;
          }

          main {
            max-width: 1040px;
            margin: 0 auto;
            padding: 1.75rem 1.5rem 3.5rem;
          }

          .mf-topbar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 1rem;
            padding: 0.75rem 1.15rem;
            margin-bottom: 1.5rem;
            background: var(--mf-dark);
            color: #effbff;
            border-radius: var(--mf-radius);
          }

          .mf-topbar a {
            color: #75dbcb;
            text-decoration: none;
            font-weight: 600;
            font-size: 0.92rem;
          }

          .mf-topbar a:hover { text-decoration: underline; }

          .mf-brand {
            font-size: 0.82rem;
            letter-spacing: 0.06em;
            text-transform: uppercase;
            color: #b7d7e0;
            font-weight: 600;
          }

          h1 {
            margin: 0 0 1.25rem;
            font-size: 1.65rem;
            font-weight: 700;
            letter-spacing: -0.015em;
            color: var(--mf-dark);
          }

          h2 {
            margin: 0 0 0.5rem;
            font-size: 1.18rem;
            color: var(--mf-dark);
          }

          h3 {
            margin: 0.9rem 0 0.35rem;
            font-size: 1rem;
            color: var(--mf-ink);
          }

          p { margin: 0.35rem 0; }

          a { color: var(--mf-accent); }
          a:hover { color: var(--mf-accent-hover); }

          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 0.86em;
            background: var(--mf-accent-soft);
            color: var(--mf-dark);
            padding: 0.14rem 0.42rem;
            border-radius: 5px;
            word-break: break-all;
          }

          section,
          .mf-card {
            background: var(--mf-surface);
            border: 1px solid var(--mf-border);
            border-radius: var(--mf-radius);
            padding: 1.25rem 1.35rem;
            margin-bottom: 1.25rem;
            box-shadow: 0 1px 2px rgba(15, 36, 48, 0.04);
          }

          article {
            margin-top: 1rem;
            padding-top: 1rem;
            border-top: 1px solid var(--mf-border);
          }

          form {
            display: flex;
            flex-wrap: wrap;
            align-items: flex-end;
            gap: 0.85rem 1rem;
            margin: 0.75rem 0;
          }

          form.mf-panel {
            background: var(--mf-surface);
            border: 1px solid var(--mf-border);
            border-radius: var(--mf-radius);
            padding: 1.15rem 1.25rem;
            margin-bottom: 1rem;
            box-shadow: 0 1px 2px rgba(15, 36, 48, 0.04);
          }

          label {
            display: flex;
            flex-direction: column;
            gap: 0.3rem;
            font-size: 0.84rem;
            font-weight: 600;
            color: var(--mf-muted);
          }

          label:has(input[type="checkbox"]) {
            flex-direction: row;
            align-items: center;
            gap: 0.45rem;
            font-weight: 500;
            color: var(--mf-ink);
          }

          input,
          select {
            font: inherit;
            font-size: 0.92rem;
            color: var(--mf-ink);
            background: #fff;
            border: 1px solid #bfd2dc;
            border-radius: 6px;
            padding: 0.46rem 0.65rem;
            min-height: 2.25rem;
          }

          input[type="checkbox"] {
            min-height: auto;
            width: 1rem;
            height: 1rem;
            accent-color: var(--mf-accent);
          }

          input:focus,
          select:focus {
            outline: 2px solid rgba(29, 111, 122, 0.25);
            border-color: var(--mf-accent);
          }

          button {
            font: inherit;
            font-size: 0.9rem;
            font-weight: 600;
            color: #fff;
            background: var(--mf-accent);
            border: 1px solid var(--mf-accent);
            border-radius: 6px;
            padding: 0.48rem 0.95rem;
            min-height: 2.25rem;
            cursor: pointer;
            transition: background 0.15s ease;
          }

          button:hover {
            background: var(--mf-accent-hover);
            border-color: var(--mf-accent-hover);
          }

          p[role="status"] {
            min-height: 1.25rem;
            font-weight: 600;
            color: var(--mf-accent);
            margin: 0.5rem 0 1rem;
          }

          p[role="status"]:empty { display: none; }

          .mf-meta {
            color: var(--mf-muted);
            font-size: 0.9rem;
          }

          .mf-stream {
            background: var(--mf-surface-alt);
            border: 1px solid var(--mf-border);
            border-radius: 8px;
            padding: 0.85rem 1rem;
            margin: 0.75rem 0;
          }

          .mf-controls {
            display: flex;
            flex-wrap: wrap;
            align-items: center;
            gap: 0.75rem 1rem;
            margin: 0.85rem 0;
            padding: 0.75rem 1rem;
            background: var(--mf-accent-soft);
            border-radius: 8px;
          }

          figure {
            margin: 0.9rem 0;
            padding: 0.85rem 1rem;
            background: #0d2230;
            color: #75dbcb;
            border-radius: 8px;
          }

          figure svg {
            width: 100%;
            height: auto;
            display: block;
          }

          figcaption {
            margin-top: 0.5rem;
            font-size: 0.82rem;
            color: #b7d7e0;
          }

          audio {
            display: block;
            margin: 0.5rem 0;
            max-width: 100%;
          }

          details {
            margin-top: 0.5rem;
            font-size: 0.9rem;
          }

          summary {
            cursor: pointer;
            font-weight: 600;
            color: var(--mf-accent);
          }

          details > div {
            padding: 0.2rem 0 0.2rem 0.9rem;
          }

          output {
            font-size: 0.85rem;
            font-weight: 600;
            color: var(--mf-muted);
          }
        </style>
        <script type="module" src="/assets/exam.js"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
