## STDX dependency
Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

# An AI programming tool that runs on the command line
## Dependencies
- `>=glm-5` `>=glm-5-coder` `glm-4.7` Zhipu search
  - glm-5 generates the spec
  - glm-5-coder generates the code
  - glm-4.7 extracts keywords from text
- Cangjie 1.1.0
- ubuntu-24.04
```bash
sudo apt update
sudo apt install binutils libc6-dev libc++-dev libgcc-11-dev
```
- openssl 3.6.1
- postgresql 18 + the zhparser plugin + xunsearch + the vector plugin
  - First install postgresql 18
  - Install xunsearch
  - Connect to postgresql 18 and run the following sql:
  ```sql
    CREATE EXTENSION zhparser;
    CREATE TEXT SEARCH CONFIGURATION chinese_english (PARSER = zhparser);
    ALTER TEXT SEARCH CONFIGURATION chinese_english ADD MAPPING FOR n,v,a,i,e,l WITH simple;
    ALTER ROLE ALL SET zhparser.punctuation_ignore = ON;
    ALTER ROLE ALL SET zhparser.multi_short = ON;
    SELECT * FROM ts_debug('chinese_english', '这是一个API接口设计文档');
    --The result below means the installation succeeded
  ```
| alias | description        | token    | dictionaries | dictionary | lexemes      |
|:------|:-------------------|:---------|:-------------|:-----------|:-------------|
| n     | noun, noun          | 这是     | ['simple']   | simple     | ['这是']     |
| m     | numeral, numeral       | 一个     | []           | <null>     | <null>       |
| e     | exclamation, interjection | API      | ['simple']   | simple     | ['api']      |
| n     | noun, noun          | 接口     | ['simple']   | simple     | ['接口']     |
| n     | noun, noun          | 设计文档 | ['simple']   | simple     | ['设计文档'] |
| v     | verb, verb          | 设计     | ['simple']   | simple     | ['设计']     |
| n     | noun, noun          | 文档     | ['simple']   | simple     | ['文档']     |

- Install the vector plugin
```
# Update the package list
sudo apt update
# Install the plugin matching your version (replace 18 with your PostgreSQL major version)
sudo apt install postgresql-18-pgvector
################ Build from source
# Clone the source (using /tmp is recommended)
cd /tmp
git clone --branch v0.8.1 https://github.com/pgvector/pgvector.git
cd pgvector

# Compile and install
make
sudo make install
```
2. Run `CREATE EXTENSION vector;` in postgres
3. Verify: `SELECT * FROM pg_extension WHERE extname = 'vector';`
4. When querying you can use SET to specify ef_search, then run the select:
    ```sql
        SET ef_search = 100;
        select ...
    ```

**Tip:** installing openssl, xunsearch and postgres plugins such as zhparser and vector produces many compatibility errors, and if you are
unfamiliar with postgresql you will also run into permission problems at first. Copy the commands you run and the errors that occur into
xiao.huawei.com and follow the replies step by step; that solves them all.

## Trigger functions
### Recording the last update time
```sql
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.update_time = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```
## Tables
[All the table creation sql](./docs/fcoder.sql)
- Large model configuration `llm_conf`
All large model configuration lives in this table; after installing this project you must save the required large models into this table
- Recording token usage `llm_token_usage`
- Knowledge `knowledge`
    - Text SQL
        ```sql
        WITH confidence AS (
             SELECT id, title, content, kind, query, search_vector,
                    (1.0 - (embedding <=> '[0.1, 0.2, ...]')) * 0.7 +  -- The string contains the vector array
                    ts_rank(search_vector, query) * 0.3 as confidence
               FROM knowledge, to_tsquery('chinese_english', '搜索的内容') as query
         )
         SELECT id, title, content
           FROM confidence
          WHERE kind IN ('<kind>',...)
            AND search_vector @@ query
            AND confidence >= 0.75                                                                                                                          
          ORDER                                                                                                                                             
             BY confidence DESC
          LIMIT 50;
        ```
- Projects `projects`
- Code `codes`
- Specification `sepcification`
- Roles `roles`
- Skills `skills`
- Problems `problems`
Temporarily records problems found during development, such as "another potential problem, somewhere that needs refactoring, or a missing test
case" noticed while fixing a BUG.
Check this table whenever a task is completed or a BUG is fixed.
Delete the problems that have been solved
- Agents `agents`

## Configuring the LLM
After creating the tables, add the large model configuration to llm_conf; tool APIs such as Zhipu search are configured here too, using the following SQL
```sql
insert into llm_conf(llm_name,llm_type,llm_url,conf,token_threshold)values('glm-5', 'text', 'https://.....','llm.key', 80000);
--For search, llm_type is 'search'; llm_name is the concrete search name, which for Zhipu is 'glm-search_std' 'glm-search_pro' 'glm-search_pro_sogou' 'glm-search_pro_quark'; everything else is the same
```
## Configuring the knowledge base, agents and skills
Run `docs/fcoder.sql`; the insert into statements follow the table creation SQL

## The relation between agents, skills, events, flows and functions
- A flow is a collection of events and agents
- Skill names must be unique
- One event is received by different agents
- One agent may receive several events and own several skills; it may also return several events
- Different agents use different skills to handle the same event
- An agent + an event determine several primary skills and several auxiliary skills
  - The number of primary skills is >= 0 and the number of auxiliary skills is >= 0
  - Primary skills are always fully loaded with the agent while auxiliary skills are loaded on demand
- One agent may join different flows; whichever flow the agent is in, it handles the same events with the same skills
- Different flows may have events with the same name but different meanings (avoid this where possible); such events must be received by different agents
- One skill can handle only one determined event and return one event that is either determined by the executed function or returned by the large model
    - For skills that do not need to execute a function, the large model may return an event directly
    - For skills that need to execute a function, the function must return an event, and it need not be a determined one
- One skill may be owned by different agents
- An agent executes a skill by calling functions according to the data returned by the large model; the functions return data and an event name
- An agent is a node of a flow. During one flow execution an agent may receive different events several times and handle them with different skills
- Skills are the edges of the flow and are atomic: they do one thing only.
    - A function is part of a skill
    - A skill may have zero or more functions
- Events are the data flowing along the skill edges between agent nodes
- The code of an agent does not need to care about the event currently being handled, nor about which skill handles the current event; it only needs to:
    1. look up the skill according to the event
    2. wrap the event and the skill into the parameters for accessing the large model
    3. execute functions according to the JSON returned by the large model
    4. build the event from the function return value and return the event
    - This way:
        - It saves the tokens spent on letting the large model decide which skill to use and which function to call.
        - There is no need to write prompts listing the skills, deciding which skill to use and which function to call
        - Since the agent executes functionality through functions rather than commands directly, edge cases can be handled inside the
          functions to prevent security problems, for example:
            - Parameter validation
            - Accidental file deletion

## session
The process heap memory keeps context along the following two dimensions:
- role
- sessionId
One agent is one thread; an agent may have several sessions, and one session has one sessionId.
The session context can be handled as needed in the following ways:
- Keep sessions short where possible
    - Start a new session at every step
        ```
        Feature: session management after user login
        [Dialogue 1] Investigate the existing code structure    ├── Understand the implementation of 【module】
            ├── Look at the current state of session management    └── Output: key file list and understanding of the current architecture
        [Dialogue 2] Implement the basic functionality   ├── Refer to the findings of dialogue 1          ├── Implement the core session saving logic
            └── Output: basic implementation code
        [Dialogue 3] Add error handling   ├── Refer to the implementation of dialogue 2          └── Add handling of edge cases
        [Dialogue 4] Write tests       ├── Refer to the implementations of dialogues 2 and 3       └── Add unit tests and integration tests
        [Dialogue 5] Code review       ├── Check whether the implementation follows the project conventions    └── Confirm that no security problems were introduced
        [Dialogue 6] Cleanup and refactoring     └── Adjust according to the review results
        ```
    - Pass context between sessions:
        - **Reference the conclusions of earlier dialogues:** briefly state the earlier findings or decisions at the start of the new dialogue
        - **Use the Git state:** let the Agent look at git diff or check the recent commits
        - **Use project documents:** record important decisions in AGENTS.md or a similar file so the Agent can read them every time
        - **Mention the relevant files directly:** #mention the files you need in the new dialogue
        - The key is: **never** try to finish everything in one dialogue. Whenever you notice that the current task is done, or the dialogue
          starts to get confusing, start a new dialogue.

- Discarding part of the session history
    - The language features of the mind skill can never be discarded
    - Whether API documentation, code conventions, specification, resource, reference, tools and code snippets are loaded is decided by the
      description of the skill
        - The JSON returned by the LLM should contain keywords such as API documentation, code conventions, specification, experience, resource,
          reference and tool; the agent queries by keyword and uses the documents it finds as the input of the next session.
        - Before every access to the LLM the agent decides what to send next according to the previous response.
- Summarizing the session history
    - Purely textual sessions are summarized every time: the content returned last time is transmitted in full, while earlier session content
      is transmitted as its summary
    - Returned code is saved to the database as well as to a file.
        - A programming skill should ask the LLM to return the code snippets that have to be sent back
        - A skill should require the generated code to contain proper comments
            - The agent extracts the comments and sends them back together with the package path, type and member definitions on the next access
        - Send the code to the code review agent
- The reasoning in the session history must be saved as well
- Business architecture agent
    - Generate interface documentation
        - http API documentation
        - In-module interface documentation
    - Generate interface code and controller class and function declarations following the DDD pattern
- The programming agent should ask the LLM to return whether testing can start; after receiving a response that testing can start, the
  programming agent sends a message to the testing agent
    - The programming skill should ask the LLM to return:
        - whether the generated code is sufficient to start testing
        - the module, package and code files to be tested
    - The programming agent sends the testing agent:
        - the module, package and code files to be tested, and the current TASK
    - Testing agent
        - Generates black-box unit test cases according to the specification as soon as the programming agent starts
        - Appends white-box unit test cases according to the received code after receiving the message from the programming agent
        - The generated unit test cases must add a detailed comment to every function explaining the purpose of the test case
- Use the default temperature when generating a specification
- The temperature when generating code is 0
- For a compilation error of one module, send back only the most recent compilation error and the code file that failed to compile
- For a test case failure, send back not only the code file but also the test case name, the purpose of the test case and the history of modifications
- Every time a BUG is fixed or a feature is completed, the **summary skill** summarizes the work, and the data source of the summary is:
    - the related spec
    - the BUG or feature description
    - the code that changed
    - the messages of the commits
- Generating documents and code and fixing BUGs need several rounds of iteration, attempts and exploration
    - The loop termination conditions
        - Every model call returns a stop reason that decides what happens next:
            - **end_turn:** the model finished its response and there is no further action to perform. This is the normal successful
              termination; the loop exits and returns the final message.
            - **tool_use:** the model wants to execute one or more tools and then continue. The loop executes the requested tools,
              appends the results to the dialogue history and then calls the model again.
            - **max_tokens:** the response of the model was truncated because it reached the token limit. This cannot be recovered within
              the current loop and the loop terminates with an error.
    - Understanding these termination conditions helps to predict the behavior of the Agent and to handle edge cases.
        - Typical tools of a Coding Agent; a fully featured Coding Agent usually needs the following kinds of tools:
            - **File operations**
                - **read_file:** read the content of a file
                - **write_file:** create or overwrite a file
                - **edit_file:** make a partial edit to a file (rather than rewriting it completely)
            - **Code execution**
                - **shell/terminal:** execute command line commands, used to run code, install dependencies, run tests, and so on
            - **Code search**
                - **grep/search:** search the code base for text or patterns
                - **semantic_search:** semantic code search
            - **Project navigation**
                - **list_directory:** list the contents of a directory
                - **find_files:** find files by pattern
            - The design of these tools directly affects the **capability boundary** of the Agent; the granularity, the parameter design and the
              return format of the tools all need careful consideration.
- For long tool outputs, mask their content with a placeholder (such as **"content omitted"**) to reduce the token count
- Reduce the output length of tools
- Flatten tool arguments; nested structures increase token consumption
- When the context is too long, summarize the earlier dialogues
- Task granularity should be as small as possible
- **Declaring completion too early:** the LLM declares the task complete while a lot of work remains; the solutions are:
    - keep the plan and the tasks outside the context
    - periodically let the agent check the task progress against the original plan
    - use structured task tracking and do not rely on the context of the agent
- **Project configuration file**
    - **WHAT:** the technology stack, the project structure, the responsibility of each module. This matters especially in a monorepo: it
      should tell the Agent which applications exist, which shared modules exist, and what each part does
    - **WHY:** the purpose of the project and the background of the design decisions. Why was this architecture chosen? Why does some code look
      unreasonable (historical debt, for example)?
    - **HOW:** how to run the project, how to test it and how to verify a change. bun or npm? What is the test command?
    - **Keep it as concise as possible:** progressive disclosure, do not show all the documents at once
        - It should stay within 300 lines; some teams even use fewer than 60
    - Do not let the agent do the job of a linter; code style guides increase the number of instructions
- Self-improving agent
    - Deposit effective working patterns as skills and describe the workflow with the skill

## A good spec
- **Architecture decision records (ADR):** explain "why it is designed this way" so that the AI does not make changes that go against the
  design intent
- **API usage examples:** more effective than pure type definitions
- **Known pitfalls and common mistakes:** tell the AI directly what it should not do

## Clear code structure
- **Clear naming:** processUserData helps the AI as much as it helps humans, unlike doStuff
- **Single responsibility:** a function that does one thing is easier to modify correctly than one that does ten
- **Explicit dependencies:** dependency injection is easier for the AI to understand and test than global variables
- **Run only the relevant tests**
- Clear, structured exception and error messages
- Design tools specifically for the LLM
    - Sometimes what is intuitive and simple for humans is not necessarily so for the LLM
    - Provide enough information: reduce the number of tool calls the Agent needs
    - Avoid filling up the context: do not return too much irrelevant information

## Engineering constraints
    - Make use of linters, formatters and git hooks
    Getting the Agent to commit frequently is a good habit (tell it in the Rules or Agent.md), but it tends to ignore instructions such as
    "make sure the build does not fail" and "fix the failing tests".
    A .git/hooks/pre-commit script can enforce the project standards
    - Prefer explicit stateless APIs over stateful ones
    - **Do not intervene too much:** if you frequently override the decisions of the Agent because "you think this name is better", you may
      actually be reducing efficiency
    - **Pay attention to the "cannot find" signal:** if the Agent repeatedly "cannot find" something in some place, consider whether your
      naming differs from what it expects
    - **Embrace common patterns:** use widely used design patterns and naming conventions; the training data of the AI is more likely to contain them
    - **Module-level style isolation:** in some modules developed mainly by the Agent, you may let the Agent keep its own style
### Pragmatic practices
1. Make the knowledge that "exists only in people's heads" explicit: write it down and put it in the documents
2. In modules led by the Agent, give the Agent more autonomy
3. In core modules that humans maintain frequently, keep a human-friendly style
4. On tool interfaces, provide AI-friendly options (such as --json output)

## Deliberate practice
### Extracting lessons from failures
- When the AI gives a wrong result, do not just say "it cannot do it" and give up. Ask yourself:
- Was my prompt clear enough?
- Did I provide enough context?
- Did I stuff too many tasks into one dialogue?
- Does this mistake reveal some systematic weakness of the AI?
### Building muscle memory, that is, the intuition for using AI
- When should a new dialogue start?
- How should the prompt of a complex task be organized?
- For a certain kind of problem, which combination of tools is the most effective?

------
## Specification-driven development
> ### Formulating the project constitution
> At the start of the project, define a set of global principles that must not be violated; this is the "constitution" of the project.
> 
> Content: code quality standards, security policy, architectural constraints (such as the mandatory technology stack), performance targets,
> user experience conventions, and so on.
> Purpose: draw the red lines for all subsequent AI-generated and human development work.
> 
> ### Defining the feature specification (Specify)
> Describe clearly in structured language "what" the feature does and "why" it is done, rather than "how" it is done.
> 
> Content:
> User stories: describe the value of the feature from the user's point of view.
> Acceptance criteria: usually in Gherkin syntax (Given-When-Then) or EARS syntax, making the boundary conditions under which the feature
> takes effect explicit.
> Input/output formats: define the data contract explicitly through JSON Schema or TypeScript interfaces.
> Output: requirements.md
> 
> ### Technical design (Plan)
> Based on the feature specification, the AI or an architect produces the complete technical implementation plan.
> 
> Content: architecture diagrams, changes to the data model, API interface definitions, the reasons for the technology choices, and the
> assessment of potential risks.
> Output: design.md
> 
> ### Task breakdown (Tasks)
> Break the macro technical plan down into atomic, executable concrete tasks.
> 
> Content: every task should contain concrete file paths, the signatures of the methods to be implemented, explicit acceptance criteria and
> the relevant dependencies.
> Output: tasks.md
> 
> ### Code generation and implementation (Implement)
> AI coding assistants (such as Claude Code, Cursor) generate the code automatically and run the preliminary unit tests strictly following
> the guidance in tasks.md and design.md.

## Guidelines for good skills
> **Atomicity:** stick to a single responsibility so that every Skill is like a building block, small and beautiful, focused on solving one
> concrete problem, which makes reuse and combination easier later.
>
> **Few-shot prompting:** this is the most important point; instead of explaining at length, give a few clear input/output examples. Examples
> are powerful, and the model grasps the format, style and behavior you want immediately from concrete examples.
>
> **Structured instructions:**
>
> 1) Set the role: give it a clear expert persona, such as "you are now a senior market analyst".
> 
> 2) Break down the steps: split the task flow into concrete step-by-step instructions and guide it to "think".
>
> 3) Draw the red lines: tell it explicitly "what it must not do" to prevent it from hallucinating freely.
>
> **Interface design:** define the input parameters and the output format of the Skill explicitly (for example always outputting JSON or
> Markdown), just like designing a software API. This makes your Skill reliably callable and integrable by other programs.
>
> **Iterative refinement:** treat skills as a product and iterate on them. Watch for "bad cases" that are not satisfactory in actual use, and
> turn them into new rules or counter-examples added to your skill definition, so that it keeps evolving, becoming smarter and more reliable.
>
> Some official best-practice guides
> https://platform.claude.com/docs/zh-CN/agents-and-tools/agent-skills/best-practices
> https://agentskills.io/specification

## Breaking down Agentic Coding with first principles: from theory to practice
<https://www.toutiao.com/article/7594421688560108058/>
> Core strategy: adopt the "short dialogues, lean context" model, break complex tasks into focused sub-dialogues, and use "compound
> engineering" to deposit everyday experience as a reusable project knowledge base, improving the developer experience and mastering the skill
> of collaborating with AI through deliberate practice.
>
> The essence of an LLM: autoregressive generation, predicting tokens one by one, where the generated content depends on the text already
> input and the content already generated. Its features include having no independent "thinking" process, the context being its entire memory,
> and probabilistic generation.
>
> The role of reinforcement learning: through the cycle of trying, giving feedback and adjusting, the model learns to call tools, interpret
> results and adjust strategies in a programming environment. The superiority of RL training in Agent tasks is emphasized: the model learns
> successful paths through exploration.
>
> How a Coding Agent works: a message-based dialogue structure with three roles, executing tasks through a tool-calling mechanism, where
> reasoning-capable models keep their thought process. Prompt caching can cache the context prefix, reducing computation and latency.
>
> Common problems and solutions: amnesia between sessions, which can be addressed with a task tracking system and generated state summaries;
> exhaustion of the context window, which can be addressed with observation masking or LLM summarization; the "dumb zone" problem, which
> requires arranging the context sensibly; newly discovered tasks being dropped, for which a recording mechanism should be established;
> declaring completion too early, for which the plan should be saved and checked periodically; choosing the wrong tool, for which the purpose
> of each tool should be made clear.
>
> Best practices: short dialogues are better than long ones, avoiding confusion and rising costs; write an effective project configuration file
> containing the project overview, key directories and development commands; optimize the developer experience to make both AI and human
> developers more efficient; design AI-friendly tools and interfaces, providing both convenient and low-level APIs; and improve the skill of
> collaborating with AI through deliberate practice.

> Once you understand the role of RL, you will see more clearly why certain ways of using it are more effective:
> **Provide clear success criteria:** when you tell the Agent "fix this bug, npm test should pass completely", you are in effect giving it a
> clear "reward signal", consistent with how it was trained
> **Allow trial and error:** the Agent learned during training to solve problems by trying; giving it several attempts is often more realistic
> than expecting success at the first try
> **Observe its decision patterns:** when the Agent makes a decision (such as reading a file first instead of modifying it directly), this
> often reflects the strategies it learned in RL training

> Physical limits
> Every model has a maximum token limit, and mainstream models are usually between 128K and 200K today. There are two fundamental reasons for
> this hard boundary:
> 1. The computational complexity of attention is usually O(n²), so doubling the context length quadruples the computation
> 2. The full attention matrix must be stored, so memory consumption grows quadratically as well
> Content beyond this length simply cannot be processed.
> The effective context is far smaller than the nominal context
> Although a model claims to support 200K tokens, this does not mean it performs well at a length of 200K.
> A model that supports 200K may start to degrade noticeably beyond 80K or 100K.
> Even with a 1M-token context window, a Coding Agent can in practice use only **10-15%** of it effectively. Beyond 20% both cost and
> performance deteriorate sharply. Most Agents forcibly interrupt at about 20%, and best practice is to restart the session before 15%.
> **Newly discovered tasks are dropped**
> - This is an easily overlooked but hugely impactful problem in Agentic Coding: the LLM notices various problems while working, but when the
> context space is tight it chooses to ignore those findings and take no action.
> **Use Chinese where possible**
> For Zhipu, one token is about 0.75 English words or 1.5 Chinese characters; other large models are similar, some having 0.75 English words
> or 0.75 Chinese characters, but for most, one token corresponds to more Chinese characters. Considering information density, the same number
> of tokens can obviously express more meaning in Chinese, and the trend becomes more pronounced as the number of tokens grows.
> To save tokens, use Chinese where possible.
