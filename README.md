# We Have AI At Home (fAI)

**Version 1.0 alpha.** Everything works and is measured; expect rough edges, and please report them.

**A self-hosted, private AI assistant for a Raspberry Pi that never makes things up, because it has no language model to make things up with.**

fAI answers questions by finding and quoting real sources, doing arithmetic on facts it can cite, and running small tools you control. Every sentence in an answer is either quoted verbatim from a page it links to, computed from data it links to, or a hand-written template that says so. If it can't find a dependable answer, it says that instead. It runs on a Raspberry Pi 4 with no cloud account, no API key and no subscription.

> "fAI" is short for *fake AI*. That's the point: it's a small program that is honest about what it is.

- 📄 **White paper:** [LLM-free question answering on a Raspberry Pi](https://github.com/sorenkylor/We-Have-AI-At-Home/blob/main/docs/fai-white-paper-llm-free-question-answering.md)
- 🚀 **Install in one command:** see [Install](#install) (the installer is the only file you need; it's this repository's [`install-noai.sh`](install-noai.sh))
- 🧪 **Measured, not promised:** see [How well does it work?](#how-well-does-it-work)

---

## Why this exists

Chatbots built on large language models are impressive and they hallucinate: in production traffic, OpenAI's own system card for GPT-5 reported that roughly one response in twenty from its best mode contained at least one major factual error, and one in five for older models. For a home assistant that tells you how to descale a kettle, what a drug interaction is, or whether your landlord can keep your deposit, "usually right" is the wrong standard.

fAI takes the opposite bet. It gives up generation entirely and asks how much of everyday chatbot use can be covered by **retrieval, structured data, deterministic reasoning and templates** on a £60 computer, and it measures the answer instead of asserting it.

## What it can do

| Ask it… | What you get |
|---|---|
| *Who wrote Dracula? What's the capital of Peru? How tall is Denali?* | A one-line fact from Wikidata, with the link |
| *Why is the sky blue? How does a thermos keep things hot?* | The passage from Wikipedia or a reputable site that explains it, quoted verbatim, chosen by a small ranking model, with the article's own defining sentence for context |
| *How do I change a flat tyre? Recipe for lentil soup?* | Numbered steps or a full recipe, extracted from a how-to page and quoted in order |
| *Best things to do in Chicago? Most popular dog breeds?* | A list ranked by how many independent sites agree, never by opinion |
| *Is Canada bigger than Australia? How far is Porto from Lisbon? How many countries border Germany? Who was US president when Elvis was born?* | Arithmetic over cited Wikidata claims: comparisons, distances, counts, superlatives, offices held on a date |
| *Compare Go and Python. Timeline of the Apollo program. Facts about Jupiter.* | Structured answers built from Wikipedia and Wikidata |
| *How do I list open ports? Turn holiday.mov into an mp3 with ffmpeg* | Commands from the tldr pages, with your file names filled in and checked by ShellCheck |
| *Define ineffable. Synonyms for happy. How do you say thank you in Portuguese?* | Wiktionary |
| *What's 18% of 350? Convert 12 miles to km. Days until Christmas? Monthly payment on $100,000 at 5%?* | Exact arithmetic, offline |
| *Remind me to water the plants in 2 hours. Add milk to my shopping list. Put dentist on my calendar Friday at 2.* | Local tools: reminders, lists, an ICS calendar, plain-text files, household notes. It asks before deleting anything and never runs commands |
| *Coffee shops near Pike Place Market* | OpenStreetMap |
| *News about NASA. What's the weather in Denver?* | Dated headlines quoted from outlets; a forecast |
| *Write a poem about autumn* | A poem from a hand-written grammar, clearly labelled as such |
| *Hi, I'm stressed about my exams* | Small talk that listens, remembers what you tell it (on your machine only), and doesn't pretend to be a person |

It follows a conversation: *"Who directed Alien?" → "and the composer?" → "no I meant the 1986 one" → "how long is it?"* Every rewrite it makes is shown to you ("I read that as …") so you can correct it.

## What it won't do

- **Write anything original.** No essays, emails, code or stories. Ask for code and it finds the documented answer and links it.
- **Guess.** When the sources don't answer the question, it says so.
- **Change quoted text.** The only edit it ever makes is dropping asides from a quoted sentence when you ask for a short answer, and it tells you it did.
- **Send your data anywhere.** Lookups go to Wikipedia, Wikidata, Wiktionary, OpenStreetMap and a self-hosted metasearch engine; nothing about you leaves the Pi.

## How well does it work?

Everything below is measured by scripts that ship with the project, on question sets the author wrote (which are easier than real traffic, and the paper says so). Run them yourself; the numbers land in your terminal.

| Measurement | Result |
|---|---|
| 1,800 checkable fact questions in noisy phrasings (lowercase, typos, "hey, … please") | **98% correct** |
| Held-out corpus in the topic mix of real chatbot use: practical guidance / seeking information / technical help | **93% / 98% / 96%** answered |
| 428 explanation and how-to questions | **97%** answered |
| Verbatim integrity: quoted answers found in their source page | **~95%** of answers checked per run |
| Blind multi-turn conversation cases, never tuned on | **35–36 of 38** |
| False-confident answers (a keyword proxy for "wrong but sure") | **4–6%** |

The biggest remaining cause of a missing answer is not the assistant: free metasearch engines suspend a home IP that asks too often. The project tracks that separately so it isn't mistaken for a failure of the method.

Things that were tried and **did not** help, reported as negative results in the [paper](https://github.com/sorenkylor/We-Have-AI-At-Home/blob/main/docs/fai-white-paper-llm-free-question-answering.md): refitting the answer-ranking weights on labelled pairs, replacing the small ranking model with an "answerability" model or a bigger one, and adding article context to the ranker.

## How it works (one screen)

```
question ─► planner (rules: what kind of question, how fresh must the answer be)
         ─► capabilities, in order of precision:
              arithmetic & dates → Wikidata facts & reasoning → Wiktionary → tldr commands
              → recipes / how-to steps / lists (cross-site agreement) → Wikipedia + web passages
              → chat templates
         ─► contract check: is the answer the shape the question asked for, from ≥1 (or ≥2) sources?
         ─► answer, with sources, or an honest "I couldn't find a dependable answer"
```

- **No language model.** Two small encoder models run on the Pi's CPU: a sentence encoder for meaning similarity and a MiniLM cross-encoder that ranks candidate passages. They *choose* text; they never *write* it.
- **Sources:** Wikipedia, Wikidata, Wiktionary, Wikiquote, OpenStreetMap, tldr-pages, MDN and Python documentation, and the open web via a bundled [SearXNG](https://github.com/searxng/searxng) instance.
- **Whole-output contract:** every answer is quoted, computed, or templated, and labelled as which.
- **Self-testing:** the installer runs a 300-question evaluation after every install, including blind cases the code was never tuned on, and prints a report.
- **Everything is Python** in a handful of files, plus a one-file bash installer that builds two Docker containers.

## Install

Tested on a Raspberry Pi 4 (4 GB) running 64-bit Raspberry Pi OS with Docker; a Pi 5 or any Linux PC with Docker works too. Allow about 6 GB of disk and half an hour for the first install (models, tldr pages and the self-test).

```bash
curl -fsSLO https://raw.githubusercontent.com/sorenkylor/We-Have-AI-At-Home/main/install-noai.sh
NOAI_CONTACT=you@example.com bash install-noai.sh
```

That's it. The installer sets up SearXNG and the app, downloads the two small models and the tldr pages, runs the self-test, and prints the URL (default `http://<pi-address>:7070`) and an access code for the tools. `NOAI_CONTACT` is the contact address Wikimedia asks polite API clients to send; nothing is sent anywhere else.

Optional: `NOAI_BRAVE_KEY=<key>` in the `.env` file enables a keyed search backend that is used only when the free engines throttle you.

## Try it

Open the URL in a browser, or from a terminal:

```bash
curl -s -X POST http://<pi-address>:7070/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"question": "Why is the Statue of Liberty green?", "session": "me"}'
```

Add `"debug": true` to see the planner's trace: what it looked up, what it found, why it chose what it chose.

## Measure it

```bash
cd ~/noai-chat-*/
docker compose exec -T app python /app/corpus.py --half facts        # ~2,000 auto-checked fact questions, about an hour
docker compose exec -T app python /app/corpus.py --half heldout      # coverage by topic
docker compose exec -T app python /app/corpus.py --scenarios         # simulated conversations, for reading
docker compose exec -T app python /app/corpus.py --day --hours 7     # a day of varied conversations
./record.sh                                                          # bundle transcripts, traces and your thumbs-up/down for analysis
```

Thumbs-up and thumbs-down buttons in the interface are stored locally and exported with the bundle; they're the project's only source of labels on real questions.

## Who is this for?

- People who want a private assistant at home that doesn't phone home and doesn't invent facts.
- Developers and researchers interested in **retrieval-only question answering**, **hallucination-free chatbots**, **small-model NLP on edge devices**, and honest measurement of coverage versus large language models.
- Anyone with a Raspberry Pi and an hour.

## Status

**1.0 alpha**, actively developed. This repository publishes the installer (which contains the whole application, the evaluation harness and the corpora), the white paper and the citation file. Everything the numbers above depend on is inside the installer, so results can be reproduced from it alone. The [white paper](https://github.com/sorenkylor/We-Have-AI-At-Home/blob/main/docs/fai-white-paper-llm-free-question-answering.md) describes the method, the measurements, their limits, and what didn't work.

## Citing

If you use this work, please cite the white paper; a `CITATION.cff` in the repository gives the reference in the usual formats.

## Contributing

Bug reports with the debug trace attached (`"debug": true` on the API, or the trace shown under a failed self-test question) are the most useful thing you can send. Question sets in the style of `corpus.py`, especially real ones, are welcome as issues. Changes should keep the contract: nothing generated, everything sourced.

## Security and privacy

The app listens on your local network and is not meant to be exposed to the internet without a reverse proxy and authentication. Tools (reminders, lists, calendar, files) are locked behind the access code the installer prints; lookups work without it. Nothing about you is sent anywhere except the contact address in the polite `User-Agent` that Wikimedia asks API clients to provide.

## License

[MIT](LICENSE). Use it, change it, sell it; keep the notice. Third-party components (SearXNG, the tldr pages, the MiniLM and model2vec models, Wikimedia content) are downloaded by the installer and keep their own licences.

---

*Keywords: self-hosted AI assistant, Raspberry Pi chatbot, offline assistant, private AI, no LLM, hallucination-free question answering, retrieval-based QA, Wikidata question answering, SearXNG, Docker, home automation assistant, open source.*
