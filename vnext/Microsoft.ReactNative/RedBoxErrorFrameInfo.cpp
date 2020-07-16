// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
#include "pch.h"
#include "RedBoxErrorFrameInfo.h"
#include "unicode.h"

namespace Mso::React {

winrt::hstring RedBoxErrorFrameInfo2::File() const noexcept {
  return ::Microsoft::Common::Unicode::Utf8ToUtf16(m_frame.File).c_str();
}

winrt::hstring RedBoxErrorFrameInfo2::Method() const noexcept {
  return ::Microsoft::Common::Unicode::Utf8ToUtf16(m_frame.Method).c_str();
}

uint32_t RedBoxErrorFrameInfo2::Line() const noexcept {
  return m_frame.Line;
}

uint32_t RedBoxErrorFrameInfo2::Column() const noexcept {
  return m_frame.Column;
}

bool RedBoxErrorFrameInfo2::Collapse() const noexcept {
  return m_frame.Collapse;
}

}
