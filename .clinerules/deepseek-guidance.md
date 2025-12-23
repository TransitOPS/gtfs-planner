# DeepSeek Model Guidance for Cline

## Critical: Tool Usage Format

You MUST use XML-style tags for ALL tool calls. This is non-negotiable - Cline cannot parse any other format.

### Required Format

Every tool call must follow this exact structure:

```
<tool_name>
<parameter1>value1</parameter1>
<parameter2>value2</parameter2>
</tool_name>
```

### Available Tools Reference

#### read_file - Read file contents

```
<read_file>
<path>relative/path/to/file.ext</path>
</read_file>
```

#### write_to_file - Create or overwrite a file

```
<write_to_file>
<path>relative/path/to/file.ext</path>
<content>
Complete file content here
</content>
</write_to_file>
```

#### replace_in_file - Make targeted edits

```
<replace_in_file>
<path>relative/path/to/file.ext</path>
<diff>
<<<<<<< SEARCH
exact content to find
=======
replacement content
>>>>>>> REPLACE
</diff>
</replace_in_file>
```

#### execute_command - Run CLI commands

```
<execute_command>
<command>your command here</command>
<requires_approval>true</requires_approval>
</execute_command>
```

#### list_files - List directory contents

```
<list_files>
<path>directory/path</path>
<recursive>false</recursive>
</list_files>
```

#### search_files - Regex search across files

```
<search_files>
<path>directory/path</path>
<regex>your regex pattern</regex>
<file_pattern>*.ts</file_pattern>
</search_files>
```

#### ask_followup_question - Ask user for clarification

```
<ask_followup_question>
<question>Your specific question here</question>
</ask_followup_question>
```

#### attempt_completion - Present final result

```
<attempt_completion>
<result>
Description of completed work
</result>
</attempt_completion>
```

## Workflow Rules

1. **ONE TOOL PER MESSAGE**: Use exactly one tool per response. Never chain multiple tools.

2. **WAIT FOR CONFIRMATION**: After each tool use, wait for the result before proceeding. Never assume success.

3. **USE THINKING TAGS**: Before each tool use, analyze in `<thinking></thinking>` tags what you need to do and which tool to use.

4. **DO NOT OUTPUT PLAIN TEXT WHEN A TOOL IS NEEDED**: If you need to read a file, create a file, or execute a command, use the appropriate tool - don't just describe what you would do.

5. **PATHS ARE RELATIVE**: All file paths should be relative to the current working directory shown in environment_details.

## Common Mistakes to Avoid

- ❌ Describing what tool you'll use instead of using it
- ❌ Using markdown code blocks instead of XML tool tags
- ❌ Using multiple tools in one response
- ❌ Forgetting required parameters
- ❌ Not using the exact XML format shown above
- ❌ Continuing without waiting for tool result confirmation

## Example Correct Response

When asked to "create a hello world file":

<thinking>
I need to create a new file. I'll use write_to_file with the path and content.
</thinking>

<write_to_file>
<path>hello.txt</path>
<content>
Hello, World!
</content>
</write_to_file>

## Response Pattern

Every response that requires action should:

1. Start with `<thinking>` analysis
2. End with exactly ONE tool use in proper XML format
3. NOT include conversational text after the tool use
