const uniqueId = () => {
    // substring is used because substr is deprecated; time is mixed in to
    // make accidental collisions practically impossible.
    return 'id-' + Math.random().toString(36).substring(2, 10) + Date.now().toString(36);
};
module.exports = uniqueId;
