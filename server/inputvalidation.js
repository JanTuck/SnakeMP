// Usernames may contain unicode letters, numbers, spaces, underscores and
// hyphens, and must be 4-16 characters long after trimming.
const USERNAME_PATTERN = /^[\p{L}\p{N}_\- ]+$/u;

class InputValidation{
    static isValidUsername(username){
        if (typeof username !== 'string') return false;
        const trimmed = username.trim();
        return trimmed.length >= 4 && trimmed.length <= 16 && USERNAME_PATTERN.test(trimmed);
    }
}
module.exports = InputValidation;
